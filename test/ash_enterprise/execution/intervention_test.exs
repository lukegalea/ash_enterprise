defmodule AshEnterprise.Execution.InterventionTest do
  @moduledoc """
  What an operator does about an invocation that went wrong
  (`AshEnterprise.Execution.Intervention`), on a referral whose acknowledgement the board
  lost (`AshEnterprise.Test.Execution.FakeBoard`): the row's outcome is unknown, its
  target has no lookup, so it waits for a person.

    * an unknown outcome is never rerun and never retried as it stands;
    * a person settles it, saying why, and the act is recorded with who did it;
    * simulating a rerun creates nothing;
    * a rerun is a new request with a new key and a link to the row it reruns;
    * a cancel says what it did, and every act shows in the trace with its actor and
      reason;
    * missing, errored and unknown inputs are refused, and nothing is written.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  require Ash.Query

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Changes.SealingScope
  alias AshEnterprise.Execution.{Intervention, Invocation, Recovery}
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
  defp as(who, ctx), do: [actor: who.actor, tenant: ctx.tenant]
  defp get(id, ctx), do: Execution.get_invocation!(id, oban(ctx))

  # The nurse refers a patient; the board takes the referral and the answer is lost.
  defp unknown!(ctx) do
    FakeBoard.mode(:lose_ack)

    row =
      Execution.invoke!(
        @unchecked,
        %{"patient" => "SYNTHETIC patient #{System.unique_integer([:positive])}"},
        %{key: "refer:#{System.unique_integer([:positive])}"},
        as(ctx.nurse, ctx)
      )

    assert :outcome_unknown = Execution.execute_invocation!(%{"id" => row.id}, oban(ctx))
    assert :resolution_requested = Execution.reconcile_invocation!(%{"id" => row.id}, oban(ctx))
    FakeBoard.mode(:accept)
    get(row.id, ctx)
  end

  defp failed!(ctx) do
    row = unknown!(ctx)

    Execution.resolve_invocation!(
      row.id,
      :failed,
      "The board has no such referral.",
      as(ctx.admin, ctx)
    )

    drain()
    get(row.id, ctx)
  end

  defp drain, do: Oban.drain_queue(queue: :execution, with_recursion: true)

  defp invocations(ctx), do: Execution.list_invocations!(oban(ctx))
  defp interventions(ctx), do: Ash.read!(Intervention, authorize?: false, tenant: ctx.tenant)

  describe "an uncertain outcome" do
    test "is never rerun and never cancelled: nothing is created", ctx do
      row = unknown!(ctx)
      before = invocations(ctx)

      assert {:error, :outcome_unknown} = Recovery.rerun(row)

      assert {:error, error} =
               Execution.rerun_invocation(row.id, "Try again.", as(ctx.admin, ctx))

      assert Exception.message(error) =~ "outcome is unknown"

      # Nor through the invocation's own rerun door.
      assert {:error, error} =
               Invocation
               |> Ash.Changeset.for_create(:rerun, %{of: row.id}, as(ctx.admin, ctx))
               |> Ash.create()

      assert Exception.message(error) =~ "outcome is unknown"

      assert {:error, _} = Execution.cancel_invocation(row.id, "Stop it.", as(ctx.admin, ctx))

      assert length(invocations(ctx)) == length(before)
      assert interventions(ctx) == []
      assert get(row.id, ctx).status == :outcome_unknown
    end

    test "is settled by a candidate, with who and why recorded and the outcome applied", ctx do
      row = unknown!(ctx)

      intervention =
        Execution.resolve_invocation!(
          row.id,
          :failed,
          "The board has no such referral.",
          as(ctx.admin, ctx)
        )

      assert {intervention.act, intervention.resolution, intervention.owner_id} ==
               {:resolve, :failed, ctx.admin.user.id}

      assert intervention.reason == "The board has no such referral."

      # Applied now, by the job the intervention enqueued, not at the next sweep.
      assert_enqueued(worker: Invocation.ApplyResolutionWorker)
      drain()

      settled = get(row.id, ctx)
      assert {settled.status, settled.resolved_by_id} == {:failed, ctx.admin.user.id}
      assert FakeBoard.calls() == 1
    end

    test "is not settled by someone who is not asked to: nothing is written", ctx do
      row = unknown!(ctx)

      assert {:error, _} =
               Execution.resolve_invocation(row.id, :succeeded, "Looks fine.", as(ctx.nurse, ctx))

      assert interventions(ctx) == []
      drain()
      assert get(row.id, ctx).status == :outcome_unknown
    end

    test "is not settled without a reason, or with an outcome that is not one of three", ctx do
      row = unknown!(ctx)

      for reason <- [nil, "", "   "] do
        assert {:error, _} =
                 Execution.resolve_invocation(row.id, :failed, reason, as(ctx.admin, ctx))
      end

      assert {:error, _} =
               Execution.resolve_invocation(row.id, :maybe, "Not sure.", as(ctx.admin, ctx))

      assert {:error, _} =
               Execution.resolve_invocation(row.id, nil, "Not sure.", as(ctx.admin, ctx))

      assert interventions(ctx) == []
      assert get(row.id, ctx).status == :outcome_unknown
    end

    test "while the outside system is still being asked, nobody is offered the choice", ctx do
      FakeBoard.mode(:lose_ack)

      row =
        Execution.invoke!(
          @unchecked,
          %{"patient" => "SYNTHETIC patient"},
          %{},
          as(ctx.nurse, ctx)
        )

      assert :outcome_unknown = Execution.execute_invocation!(%{"id" => row.id}, oban(ctx))
      row = get(row.id, ctx)

      assert {:error, :not_asked_yet} = Recovery.settle(row)

      assert {:error, error} =
               Execution.resolve_invocation(
                 row.id,
                 :succeeded,
                 "It went through.",
                 as(ctx.admin, ctx)
               )

      assert Exception.message(error) =~ "still being asked"
      assert interventions(ctx) == []
    end
  end

  describe "a rerun" do
    test "simulating it creates nothing and says what would run", ctx do
      row = failed!(ctx)
      before = invocations(ctx)

      preview = Execution.simulate_rerun!(row.id, as(ctx.admin, ctx))

      assert %{
               rerunnable: true,
               resolves: true,
               definition_changed: false,
               arguments: :valid,
               reaches_outside: true,
               idempotent: false,
               runs_as: runs_as
             } = preview

      assert runs_as == ctx.admin.user.id
      assert invocations(ctx) == before
      assert [%{act: :resolve}] = interventions(ctx)
    end

    test "simulating one that may not be rerun says so, and creates nothing", ctx do
      row = unknown!(ctx)
      before = invocations(ctx)

      assert %{rerunnable: false, refusal: refusal} =
               Execution.simulate_rerun!(row.id, as(ctx.admin, ctx))

      assert refusal =~ "outcome is unknown"
      assert invocations(ctx) == before
    end

    test "is a new request with a new key, linked to the row it reruns", ctx do
      row = failed!(ctx)

      intervention =
        Execution.rerun_invocation!(
          row.id,
          "Refer again now the board is up.",
          as(ctx.admin, ctx)
        )

      rerun = get(intervention.rerun_id, ctx)

      assert rerun.id != row.id
      assert rerun.invocation_key != row.invocation_key
      assert String.starts_with?(rerun.invocation_key, "rerun:#{row.id}:")
      assert rerun.rerun_of_id == row.id
      assert rerun.target == row.target
      assert rerun.owner_id == ctx.admin.user.id
      assert rerun.status == :ready
      assert {intervention.act, intervention.owner_id} == {:rerun, ctx.admin.user.id}

      # The original stays as it was.
      assert get(row.id, ctx).status == :failed

      # The same arguments as recorded.
      [original_args, rerun_args] =
        for id <- [row.id, rerun.id],
            do: Ash.load!(get(id, ctx), [:args], oban(ctx)).args

      assert original_args == rerun_args
    end

    test "takes no arguments of the caller's own", ctx do
      row = failed!(ctx)

      assert {:error, error} =
               Invocation
               |> Ash.Changeset.for_create(
                 :rerun,
                 %{of: row.id, args: %{"patient" => "someone else"}},
                 as(ctx.admin, ctx)
               )
               |> Ash.create()

      assert Exception.message(error) =~ "runs the arguments that were asked for"
    end

    test "of a row the person cannot read, or that does not exist, is refused", ctx do
      row = failed!(ctx)
      stranger = tenant!()

      for {id, who, tenant} <- [
            {row.id, ctx.nurse, ctx.tenant},
            {Ash.UUID.generate(), ctx.admin, ctx.tenant},
            {row.id, stranger, stranger.tenant}
          ] do
        assert {:error, _} =
                 Execution.rerun_invocation(id, "Again.", actor: who.actor, tenant: tenant)

        assert {:error, _} = Execution.simulate_rerun(id, actor: who.actor, tenant: tenant)
      end

      assert [%{act: :resolve}] = interventions(ctx)
      assert Enum.filter(invocations(ctx), & &1.rerun_of_id) == []
    end

    test "without a reason is refused, and nothing is created", ctx do
      row = failed!(ctx)
      before = invocations(ctx)

      for reason <- [nil, ""] do
        assert {:error, _} = Execution.rerun_invocation(row.id, reason, as(ctx.admin, ctx))
      end

      assert invocations(ctx) == before
      assert [%{act: :resolve}] = interventions(ctx)
    end
  end

  describe "a cancel" do
    test "stops a request that has not run, and is recorded", ctx do
      row = failed!(ctx)
      %{rerun_id: rerun_id} = Execution.rerun_invocation!(row.id, "Again.", as(ctx.admin, ctx))

      cancel =
        Execution.cancel_invocation!(rerun_id, "Asked by mistake.", as(ctx.admin, ctx))

      assert {cancel.act, cancel.reason} == {:cancel, "Asked by mistake."}
      assert get(rerun_id, ctx).status == :cancelled

      # A finished row is not cancelled again.
      assert {:error, _} = Execution.cancel_invocation(rerun_id, "Again.", as(ctx.admin, ctx))
      assert {:error, _} = Execution.cancel_invocation(row.id, "Undo it.", as(ctx.admin, ctx))
      assert length(interventions(ctx)) == 3
    end
  end

  describe "the trace" do
    test "shows every act under its invocation with who did it and why, and the rerun under it",
         ctx do
      row = failed!(ctx)

      %{rerun_id: rerun_id} =
        Execution.rerun_invocation!(row.id, "Board is back.", as(ctx.admin, ctx))

      %{entries: entries, sources: sources} =
        Execution.trace!(%{root_ref: "invocation:#{row.id}"}, as(ctx.admin, ctx))

      assert Enum.find(sources, &(&1.source == :intervention)).status == :complete

      acts = Enum.filter(entries, &(&1.source == :intervention))
      assert length(acts) == 2

      assert Enum.all?(acts, &(&1.parent_ref == "invocation:#{row.id}"))
      assert Enum.all?(acts, &(&1.actor_label == "person:#{ctx.admin.user.id}"))
      summaries = Enum.map(acts, & &1.summary)
      assert "settled as failed: The board has no such referral." in summaries
      assert "rerun as a new request: Board is back." in summaries
      refute Enum.any?(summaries, &(&1 =~ rerun_id))

      rerun = Enum.find(entries, &(&1.source_ref == "invocation:#{rerun_id}"))
      assert rerun.parent_ref == "invocation:#{row.id}"
    end
  end

  describe "another person's request" do
    test "rerun by someone else is sealed where the original was: the requester's erasure erases both",
         ctx do
      row = failed!(ctx)
      %{rerun_id: rerun_id} = Execution.rerun_invocation!(row.id, "Again.", as(ctx.admin, ctx))

      scope =
        Erasure.Scope
        |> Ash.Query.filter(ref == ^SealingScope.scope_ref(ctx.nurse.user.id))
        |> Ash.read_one!(authorize?: false)

      assert get(row.id, ctx).erasure_scope_id == scope.id
      assert get(rerun_id, ctx).erasure_scope_id == scope.id

      Erasure.shred_scope!(scope, scope.ref, "the nurse asked", authorize?: false)

      for id <- [row.id, rerun_id] do
        erased = Ash.load!(get(id, ctx), [:args, :recorded?], oban(ctx))
        assert erased.recorded? == false, "invocation #{id} still readable after the shred"
        assert Shredded.shredded?(erased.args)
      end

      # A shredded original is no longer rerun: its arguments are gone.
      assert {:error, error} = Execution.rerun_invocation(row.id, "Again.", as(ctx.admin, ctx))
      assert Exception.message(error) =~ "erased"
    end

    test "its requester reads what others did on it, though they did not do it", ctx do
      requester =
        member!(ctx.admin, "Requester #{System.unique_integer([:positive])}", [
          {Invocation, :read, :basic}
        ])

      row = failed!(Map.put(ctx, :nurse, requester))

      assert [%{act: :resolve, owner_id: owner_id}] =
               Execution.list_interventions!(
                 Keyword.put(as(requester, ctx), :query, filter: [invocation_id: row.id])
               )

      assert owner_id == ctx.admin.user.id

      # Not anyone else's: a member who cannot read the request reads none of its acts.
      assert [] =
               Execution.list_interventions!(
                 Keyword.put(as(ctx.nurse, ctx), :query, filter: [invocation_id: row.id])
               )
    end
  end

  describe "the rules" do
    test "an unknown, missing or unreadable status is offered nothing" do
      for row <- [%{status: :sideways}, %{status: nil}, %{}] do
        assert {:error, :unknown_status} = Recovery.rerun(row)
        assert {:error, :unknown_status} = Recovery.cancel(row)
        assert {:error, :unknown_status} = Recovery.settle(row)
      end
    end

    test "a request parked on its requester's answer may be cancelled, never rerun or settled" do
      parked = %{status: :request_info, run_id: nil, process_instance_id: nil}
      assert :ok = Recovery.cancel(parked)
      assert {:error, :not_finished} = Recovery.rerun(parked)
      assert {:error, :not_finished} = Recovery.settle(parked)
    end

    test "an uncertain outcome is offered only settling, once someone is asked" do
      unknown = %{status: :outcome_unknown, resolution_requested_at: nil}
      assert {:error, :outcome_unknown} = Recovery.rerun(unknown)
      assert {:error, :outcome_unknown} = Recovery.cancel(unknown)
      assert {:error, :not_asked_yet} = Recovery.settle(unknown)

      asked = %{unknown | resolution_requested_at: DateTime.utc_now()}
      assert :ok = Recovery.settle(asked)
      assert {:error, :outcome_unknown} = Recovery.rerun(asked)
    end

    test "a run's or a process's call is rerun from its run or process" do
      for {field, reason} <- [run_id: :belongs_to_run, process_instance_id: :belongs_to_process] do
        row =
          Map.put(
            %{status: :failed, run_id: nil, process_instance_id: nil},
            field,
            Ash.UUID.generate()
          )

        assert {:error, ^reason} = Recovery.rerun(row)
      end
    end
  end
end
