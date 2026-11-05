defmodule AshEnterprise.Assistant.DecisionsTest do
  @moduledoc """
  The assistant's decisions on synthetic data: the lookups that name them
  (`pending_approvals`, `steward_queue`, each row with its id) and what it may ask for
  (`approve_task`, `reject_task`, `merge_duplicate`, `keep_duplicate_separate`,
  `mark_duplicate_unsure`). Each is a governed invocation requested as the person
  (ADR 0055) that waits for their Confirm (`AshEnterprise.Assistant.Requests`) and then
  runs through the real action as them; a decision that is not theirs is never made.
  """

  use AshEnterprise.DataCase, async: false

  alias AshAgent.Run.Toolset
  alias AshEnterprise.Assistant.Requests
  alias AshEnterprise.Bpmn.{HumanTask, TaskCandidate}
  alias AshEnterprise.Execution
  alias AshEnterprise.Mdm.MatchCandidate
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Test.AssistantFixtures, as: F

  setup do
    F.in_zone!()
    F.tenant!()
  end

  # A new request: the person's context built after the rows exist.
  defp fresh(ctx),
    do: %{
      ctx
      | actor: ActorContext.attach(ctx.user, ActorContext.build(ctx.user, tenant: ctx.tenant))
    }

  defp approval!(ctx, name, user) do
    task =
      HumanTask.create!(%{node_id: "Review", name: name}, tenant: ctx.tenant, authorize?: false)

    TaskCandidate.create!(%{task_id: task.id, principal_type: :user, principal_id: user.id},
      tenant: ctx.tenant,
      authorize?: false
    )

    task
  end

  # What a run's call to `target` asks for, requested as the person.
  defp request!(ctx, target, args) do
    Execution.invoke!(
      "AshEnterprise." <> target,
      args,
      %{key: "assistant-test:#{Ash.UUID.generate()}"},
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  defp status(task),
    do: Ash.get!(HumanTask, task.id, tenant: task.organization_id, authorize?: false).status

  defp candidate(candidate),
    do:
      Ash.get!(MatchCandidate, candidate.id, tenant: candidate.organization_id, authorize?: false)

  test "the model names each decision as the assistant declares it" do
    assert Toolset.tool_name(HumanTask, :approve) == "approve_task"
    assert Toolset.tool_name(HumanTask, :reject) == "reject_task"
    assert Toolset.tool_name(MatchCandidate, :confirm) == "merge_duplicate"
    assert Toolset.tool_name(MatchCandidate, :reject) == "keep_duplicate_separate"
    assert Toolset.tool_name(MatchCandidate, :escalate) == "mark_duplicate_unsure"
  end

  describe "a task decision" do
    test "is asked for by id, waits for the person, and runs as them", ctx do
      bob = F.colleague!(ctx)
      contract = approval!(ctx, "SYNTHETIC vendor contract sign-off", ctx.user)
      budget = approval!(ctx, "SYNTHETIC budget exception", bob.user)
      ctx = fresh(ctx)

      assert [row] = F.tool!(ctx, :pending_approvals, %{})
      assert row["task"] == "SYNTHETIC vendor contract sign-off"
      assert row["id"] == contract.id
      assert row["decisions"] == ["approve", "reject"]

      request = request!(ctx, "Bpmn.HumanTask.approve", %{"record_id" => contract.id})
      assert request.status == :awaiting_approval
      assert status(contract) == :open

      assert %{kind: :approve_task, task: "SYNTHETIC vendor contract sign-off"} =
               Requests.describe(request, ctx.actor, ctx.tenant)

      # Their own request waits on them too, but it is not a decision to ask for again.
      ctx = fresh(ctx)
      assert [%{"id" => id}] = F.tool!(ctx, :pending_approvals, %{})
      assert id == contract.id

      # Nobody else confirms it.
      assert {:error, :not_found} = Requests.confirm(request.id, fresh(bob).actor, ctx.tenant)
      assert status(contract) == :open

      assert {:ok, %{status: :succeeded}} = Requests.confirm(request.id, ctx.actor, ctx.tenant)
      assert status(contract) == :completed
      assert status(budget) == :open
    end

    test "a task that is not theirs is never decided", ctx do
      bob = F.colleague!(ctx)
      budget = approval!(ctx, "SYNTHETIC budget exception", bob.user)
      ctx = fresh(ctx)

      assert F.tool!(ctx, :pending_approvals, %{}) == []

      request = request!(ctx, "Bpmn.HumanTask.approve", %{"record_id" => budget.id})

      {:ok, decided} =
        if request.status == :awaiting_approval,
          do: Requests.confirm(request.id, ctx.actor, ctx.tenant),
          else: {:ok, request}

      assert decided.status in [:rejected, :failed]
      assert status(budget) == :open
    end

    test "declining it decides nothing", ctx do
      contract = approval!(ctx, "SYNTHETIC vendor contract sign-off", ctx.user)
      ctx = fresh(ctx)

      request = request!(ctx, "Bpmn.HumanTask.reject", %{"record_id" => contract.id})
      assert %{kind: :reject_task} = Requests.describe(request, ctx.actor, ctx.tenant)

      assert {:ok, %{status: :rejected, error_code: "approval_rejected"}} =
               Requests.decline(request.id, ctx.actor, ctx.tenant)

      assert status(contract) == :open
    end
  end

  describe "a steward verdict" do
    test "is asked for by id, shows both sides, and merges as them", ctx do
      {avery, _staged, _golden} =
        AshEnterprise.Mdm.TestSupport.staged_candidate!(
          ctx.tenant,
          ctx.user,
          "Avery Synthetic",
          "avery@example.test"
        )

      ctx = fresh(ctx)

      assert [%{"may_decide" => true} = row] = F.tool!(ctx, :steward_queue, %{})
      assert row["incoming"] == "Avery Synthetic"
      assert row["existing"] == "Avery Synthetic Existing"
      assert row["id"] == avery.id

      request = request!(ctx, "Mdm.MatchCandidate.confirm", %{"id" => avery.id})
      assert request.status == :awaiting_approval
      assert candidate(avery).status == :pending

      assert %{
               kind: :merge_duplicate,
               incoming: "Avery Synthetic",
               existing: "Avery Synthetic Existing"
             } = Requests.describe(request, ctx.actor, ctx.tenant)

      assert {:ok, %{status: :succeeded}} = Requests.confirm(request.id, ctx.actor, ctx.tenant)
      assert candidate(avery).status == :confirmed
      assert [] = F.tool!(fresh(ctx), :steward_queue, %{})
    end

    test "unsure keeps it in the queue", ctx do
      {avery, _staged, _golden} =
        AshEnterprise.Mdm.TestSupport.staged_candidate!(
          ctx.tenant,
          ctx.user,
          "Avery Synthetic",
          "avery@example.test"
        )

      ctx = fresh(ctx)
      request = request!(ctx, "Mdm.MatchCandidate.escalate", %{"id" => avery.id})
      assert %{kind: :mark_duplicate_unsure} = Requests.describe(request, ctx.actor, ctx.tenant)

      assert {:ok, %{status: :succeeded}} = Requests.confirm(request.id, ctx.actor, ctx.tenant)
      assert candidate(avery).status == :pending
    end

    test "a duplicate whose golden the person may not read is not theirs", ctx do
      bob = F.colleague!(ctx)

      {_candidate, staged, _golden} =
        AshEnterprise.Mdm.TestSupport.staged_candidate!(
          ctx.tenant,
          ctx.user,
          "Blair Synthetic",
          "blair@example.test"
        )

      golden =
        AshEnterprise.Canonical.Person
        |> Ash.Changeset.for_create(:upsert_from_source, %{
          name: "Blair Synthetic Theirs",
          owner_id: bob.user.id,
          owning_business_unit_id: bob.user.owning_business_unit_id
        })
        |> Ash.create!(tenant: ctx.tenant, authorize?: false)

      hidden =
        MatchCandidate
        |> Ash.Changeset.for_create(:create, %{
          staged_record_id: staged.id,
          golden_resource: "AshEnterprise.Canonical.Person",
          golden_id: golden.id,
          score: Decimal.new("0.70"),
          explanation: %{}
        })
        |> Ash.create!(tenant: ctx.tenant, authorize?: false)
        |> Ash.Changeset.for_update(:update, %{band: :review},
          tenant: ctx.tenant,
          authorize?: false
        )
        |> Ash.update!(tenant: ctx.tenant, authorize?: false)

      ctx = fresh(ctx)

      # The queue counts and lists only the one they may decide...
      assert [row] = F.tool!(ctx, :steward_queue, %{})
      refute row["existing"] =~ "Theirs"

      # ...and asking for the other by its id merges nothing.
      request = request!(ctx, "Mdm.MatchCandidate.confirm", %{"id" => hidden.id})

      {:ok, decided} =
        if request.status == :awaiting_approval,
          do: Requests.confirm(request.id, ctx.actor, ctx.tenant),
          else: {:ok, request}

      assert decided.status in [:rejected, :failed]
      assert candidate(hidden).status == :pending
    end
  end
end
