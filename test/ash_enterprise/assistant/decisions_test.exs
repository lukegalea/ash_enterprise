defmodule AshEnterprise.Assistant.DecisionsTest do
  @moduledoc """
  The assistant's decisions (`propose_decision`, `Proposal.decide_task/5`,
  `Proposal.steward_verdict/4`) and the lookups behind them, on synthetic
  data: a decision resolves only through the engine's candidacy read or the
  person's steward queue, it is rebuilt and authorized again as whoever
  confirms it, and it runs through the real actions as that person. Plus the
  settlement rows that let a proposal outlive the page.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.AI.Proposal
  alias AshEnterprise.Assistant.{ProposalSettlement, Propose, Thread}
  alias AshEnterprise.Bpmn.{HumanTask, TaskCandidate}
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

  defp propose!(ctx, input) do
    Propose
    |> Ash.ActionInput.for_action(:propose_decision, input,
      actor: ctx.actor,
      tenant: ctx.tenant,
      context: %{AshEnterprise.Assistant.ZoneGate.key() => F.target()},
      authorize?: true
    )
    |> Ash.run_action!()
  end

  defp status(task),
    do: Ash.get!(HumanTask, task.id, tenant: task.organization_id, authorize?: false).status

  describe "a task decision" do
    test "resolves among the tasks waiting on the person and runs as them", ctx do
      bob = F.colleague!(ctx)
      contract = approval!(ctx, "SYNTHETIC vendor contract sign-off", ctx.user)
      budget = approval!(ctx, "SYNTHETIC budget exception", bob.user)
      ctx = fresh(ctx)

      assert %{"count" => 1, "approvals" => [row]} = F.tool!(ctx, :pending_approvals, %{})
      assert row["task"] == "SYNTHETIC vendor contract sign-off"
      assert row["decisions"] == ["approve", "reject"]

      result = propose!(ctx, %{on: :task, decision: :approve, target: row["ref"]})

      assert %{"kind" => "decide_task", "task_id" => id, "decision" => "approve"} =
               result["proposal"]

      assert id == contract.id
      assert result["effect"] =~ "completes as approved"

      # Not theirs: the colleague's task is not among theirs, whatever it is called.
      refused = propose!(ctx, %{on: :task, decision: :approve, target: "budget exception"})
      assert refused["error"] =~ "No task waiting on you matches"

      # Always named: "approve it" is not a guess the tool makes.
      assert propose!(ctx, %{on: :task, decision: :approve})["error"] =~ "say which task"

      # Rebuilt as somebody else, the wire form is nothing to them.
      assert {:error, _} = Proposal.from_wire(result["proposal"], fresh(bob).actor, ctx.tenant)

      assert {:ok, proposal} = Proposal.from_wire(result["proposal"], ctx.actor, ctx.tenant)
      assert proposal.details[:task] == "SYNTHETIC vendor contract sign-off"
      assert {:ok, message} = Proposal.execute(proposal, ctx.actor, ctx.tenant)
      assert message =~ "Approved"
      assert status(contract) == :completed
      assert status(budget) == :open

      # Decided: it no longer waits on them, so the same wire form is refused.
      assert {:error, _} = Proposal.from_wire(result["proposal"], fresh(ctx).actor, ctx.tenant)
    end

    test "a merge or a keep-separate is not a task's decision", ctx do
      approval!(ctx, "SYNTHETIC vendor contract sign-off", ctx.user)
      ctx = fresh(ctx)

      refused = propose!(ctx, %{on: :task, decision: :merge, target: "vendor contract"})
      assert refused["error"] =~ "approve or reject"
    end

    test "by kind, through decision/4", ctx do
      approval!(ctx, "SYNTHETIC vendor contract sign-off", ctx.user)
      ctx = fresh(ctx)

      assert {:ok, %Proposal{kind: :decide_task, action: :reject}} =
               Proposal.decision(:decide_task, ctx.actor, ctx.tenant, %{
                 task: "vendor contract",
                 decision: :reject
               })

      assert {:error, _} = Proposal.decision(:steward_verdict, ctx.actor, ctx.tenant, nil)
      assert Proposal.decision_kinds() == [:decide_brief, :decide_task, :steward_verdict]
    end
  end

  describe "a steward verdict" do
    test "resolves in the person's queue, shows both sides, and merges as them", ctx do
      {candidate, _staged, _golden} =
        AshEnterprise.Mdm.TestSupport.staged_candidate!(
          ctx.tenant,
          ctx.user,
          "Avery Synthetic",
          "avery@example.test"
        )

      ctx = fresh(ctx)

      assert %{"count" => 1, "may_decide" => true, "duplicates" => [row]} =
               F.tool!(ctx, :steward_queue, %{})

      assert row["incoming"] == "Avery Synthetic"
      assert row["existing"] == "Avery Synthetic Existing"

      result = propose!(ctx, %{on: :duplicate, decision: :merge})

      assert result["proposal"] == %{
               "kind" => "steward_verdict",
               "candidate_id" => candidate.id,
               "verdict" => "confirm"
             }

      assert result["proposed"] =~ "Merge \"Avery Synthetic\" into \"Avery Synthetic Existing\""

      {:ok, proposal} = Proposal.from_wire(result["proposal"], ctx.actor, ctx.tenant)
      assert proposal.details[:email_kept] == "the incoming record's"

      assert {:ok, %MatchCandidate{status: :confirmed}} =
               Proposal.execute(proposal, ctx.actor, ctx.tenant)

      assert %{"count" => 0} = F.tool!(ctx, :steward_queue, %{})
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
      assert %{"count" => 1, "duplicates" => [row]} = F.tool!(ctx, :steward_queue, %{})
      refute row["existing"] =~ "Theirs"

      # ...and the other, named by id, resolves to nothing.
      refused = propose!(ctx, %{on: :duplicate, decision: :merge, target: hidden.id})
      assert refused["error"] =~ "No duplicate waiting for you has that ref"

      wire = %{"kind" => "steward_verdict", "candidate_id" => hidden.id, "verdict" => "confirm"}
      assert {:error, _} = Proposal.from_wire(wire, ctx.actor, ctx.tenant)
    end
  end

  describe "settlements" do
    test "one confirm per proposal, on the person's own thread only", ctx do
      {:ok, thread} = Thread.start("SYNTHETIC", actor: ctx.actor, tenant: ctx.tenant)
      opts = [actor: ctx.actor, tenant: ctx.tenant]

      assert {:ok, _} = ProposalSettlement.settle(thread.id, "p0123", :confirmed, opts)
      assert {:error, _} = ProposalSettlement.settle(thread.id, "p0123", :confirmed, opts)
      assert {:ok, _} = ProposalSettlement.settle(thread.id, "p0123", :failed, opts)

      assert [:confirmed, :failed] =
               thread.id |> ProposalSettlement.for_thread!(opts) |> Enum.map(& &1.outcome)

      bob = F.colleague!(ctx, admin?: true)
      bob_opts = [actor: bob.actor, tenant: ctx.tenant]
      assert {:error, _} = ProposalSettlement.settle(thread.id, "p9999", :cancelled, bob_opts)
      assert ProposalSettlement.for_thread!(thread.id, bob_opts) == []
    end
  end
end
