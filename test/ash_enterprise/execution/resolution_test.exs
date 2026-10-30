defmodule AshEnterprise.Execution.ResolutionTest do
  @moduledoc """
  A person settles an invocation whose outcome is unknown (ADR 0055): the outside call's
  acknowledgement was lost, its target has no lookup that can tell, so the row waits on
  a resolution task, and an administrator records `succeeded`, `failed` or `retry` on it
  through `HumanTask.resolve`. The `:apply_resolution` trigger applies the decision, and
  the row follows.

  The outside board is `AshEnterprise.Test.Execution.FakeBoard`, a `Req.Test` stub
  behind the Nango façade.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, actor: 1]

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Invocation, Resolution}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.Execution.FakeBoard

  @unchecked "AshEnterprise.Test.Execution.ReferralBoard.refer_unchecked"

  setup do
    FakeBoard.start!()
    admin = tenant!()
    nurse = member!(admin, "Nurse #{System.unique_integer([:positive])}", [])
    %{admin: admin, nurse: nurse, tenant: admin.tenant}
  end

  defp oban(ctx), do: [actor: SystemActor.oban(), tenant: ctx.tenant]
  defp get(row, ctx), do: Execution.get_invocation!(row.id, oban(ctx))

  # The nurse refers a patient; the board takes the referral and the answer is lost.
  defp unknown!(ctx) do
    FakeBoard.mode(:lose_ack)

    row =
      Execution.invoke!(
        @unchecked,
        %{"patient" => "SYNTHETIC patient #{System.unique_integer([:positive])}"},
        %{key: "refer:#{System.unique_integer([:positive])}"},
        actor: ctx.nurse.actor,
        tenant: ctx.tenant
      )

    assert :outcome_unknown = Execution.execute_invocation!(%{"id" => row.id}, oban(ctx))
    assert :resolution_requested = Execution.reconcile_invocation!(%{"id" => row.id}, oban(ctx))
    FakeBoard.mode(:accept)
    get(row, ctx)
  end

  defp resolution_task(row, ctx) do
    key = Resolution.key()
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.read_one!(authorize?: false, tenant: ctx.tenant)
  end

  defp act(action, task, who, ctx, extra \\ %{}) do
    HumanTask
    |> Ash.ActionInput.for_action(action, Map.put(extra, :record_id, task.id),
      actor: actor(who.user),
      tenant: ctx.tenant
    )
    |> Ash.run_action()
  end

  defp apply_resolutions do
    AshOban.Test.schedule_and_run_triggers({Invocation, :apply_resolution},
      drain_queues?: true
    )
  end

  test "an unknown outcome waits on a task the administrators may resolve", ctx do
    row = unknown!(ctx)
    assert {row.status, row.error_code} == {:outcome_unknown, "server_error"}

    task = resolution_task(row, ctx)
    assert {task.status, task.instance_id} == {:open, nil}
    assert task.subject_type == to_string(Invocation)

    # Nothing applies it until someone decides.
    apply_resolutions()
    assert get(row, ctx).status == :outcome_unknown

    # The requester holds no role and is not a candidate.
    assert {:error, _} = act(:resolve, task, ctx.nurse, ctx, %{outcome: :succeeded})
    assert get(row, ctx).status == :outcome_unknown
  end

  for {outcome, status} <- [succeeded: :succeeded, failed: :failed, retry: :ready] do
    test "an administrator records #{outcome} and the row follows", ctx do
      row = unknown!(ctx)
      task = resolution_task(row, ctx)

      assert {:ok, _message} =
               act(:resolve, task, ctx.admin, ctx, %{outcome: unquote(outcome)})

      assert %{status: :completed, outcome: outcome} = resolution_task(row, ctx)
      assert outcome == to_string(unquote(outcome))

      apply_resolutions()

      resolved = get(row, ctx)
      assert resolved.status == unquote(status)
      assert resolved.resolved_by_id == ctx.admin.user.id
      assert resolved.reconciled_via == "operator"

      if unquote(outcome) == :retry do
        # Ready again with its `:execute` job enqueued in the same transaction; run, it
        # refers the patient a second time, on purpose: the operator said the first
        # referral did not happen.
        assert_enqueued(
          worker: Invocation.ExecuteWorker,
          args: %{"primary_key" => %{"id" => row.id}}
        )

        assert :succeeded = Execution.execute_invocation!(%{"id" => row.id}, oban(ctx))
        assert FakeBoard.calls() == 2
      else
        assert FakeBoard.calls() == 1
      end
    end
  end

  test "a resolution task is decided only through resolve, and resolve only decides one",
       ctx do
    row = unknown!(ctx)
    task = resolution_task(row, ctx)

    for action <- [:approve, :reject] do
      assert {:error, error} = act(action, task, ctx.admin, ctx)
      assert Exception.message(error) =~ "resolve it with succeeded, failed or retry"
    end

    assert resolution_task(row, ctx).status == :open

    # Nor through the board's Complete, once claimed.
    assert {:ok, _} = act(:claim_task, task, ctx.admin, ctx)

    assert {:error, error} =
             act(:complete_task, task, ctx.admin, ctx, %{outcome: :approved})

    assert Exception.message(error) =~ "resolve it with succeeded, failed or retry"
    assert resolution_task(row, ctx).status == :claimed

    # And resolve refuses any other task.
    approval = %{task | node_id: "invocation.approval"}
    assert {:error, _} = Resolution.check(approval, :resolve)
    assert :ok = Resolution.check(approval, :decide)
  end

  test "the board offers exactly the three outcomes" do
    %{arguments: arguments} = Ash.Resource.Info.action(HumanTask, :resolve)
    outcome = Enum.find(arguments, &(&1.name == :outcome))
    assert outcome.constraints[:one_of] == [:succeeded, :failed, :retry]
    assert Resolution.outcomes() == ~w(succeeded failed retry)
  end
end
