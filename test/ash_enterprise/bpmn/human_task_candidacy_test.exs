defmodule AshEnterprise.Bpmn.HumanTaskCandidacyTest do
  @moduledoc """
  Only a task's candidates decide it (roadmap q24, ADR 0015).

  Who may decide a human task is the engine's candidate list, materialised as
  `TaskCandidate` rows and precomputed into the actor's context
  (`AshEnterprise.Security.Checks.TaskCandidacy`). The positive case, the candidate
  approving, is pinned elsewhere; this file pins the refusals next to it:

    * a member of the same tenant with no grants at all: no policy admits them, and the
      decision is `Forbidden`;
    * a member who can read every task through a role grant but is not a candidate: the
      policies admit the decision actions (a generic action names no row) and the read
      finds the task, so the engine's candidacy check is the only gate, and it refuses
      them as `Forbidden`;
    * a member who is a candidate for a task of their own: `TaskCandidacy` lets them run
      the decision actions, but they cannot read this task, so it is not found;
    * a candidate in another tenant: not found under their own tenant, `Forbidden` under
      this one.

  Each is refused before anything is written: the task stays open and the brief still
  waits on it.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Bpmn.{HumanTask, TaskCandidate}

  @human_only [:approve, :reject, :request_info, :resolve, :settle, :answer]

  setup do
    ctx = tenant!()
    brief = brief!(ctx)
    # A fresh context: the candidate's task ids are computed when it is built.
    candidate = actor(ctx.user)
    [task] = awaiting(candidate, ctx.tenant)
    Map.merge(ctx, %{brief: brief, candidate: candidate, task: task})
  end

  test "the task's candidate decides it", ctx do
    assert can_decide?(ctx.task, :approve, ctx.candidate, ctx.tenant)

    assert {:ok, "Approved — Approve the brief."} =
             decide(ctx.task, :approve, ctx.candidate, ctx.tenant)

    assert %{status: :approved} = reload_brief!(ctx.brief, ctx.tenant)
    assert [] == awaiting(actor(ctx.user), ctx.tenant)
  end

  test "a member of the same tenant who is not a candidate cannot decide the task", ctx do
    member = member!(ctx, "Not a candidate", [])

    for action <- @human_only do
      refute can_decide?(ctx.task, action, member.actor, ctx.tenant),
             "#{action} reached a member who is not a candidate"
    end

    assert {:error, %Ash.Error.Forbidden{}} =
             decide(ctx.task, :approve, member.actor, ctx.tenant)

    assert_still_open(ctx)
  end

  test "a member who can read every task but is not a candidate cannot decide one", ctx do
    reader =
      member!(ctx, "Task reader", [
        {HumanTask, :read, :global},
        {TaskCandidate, :read, :global}
      ])

    # The role grant reaches the task, so the refusal below is not "not found": the
    # reader gets past the policies (a generic action names no row) and the engine's
    # candidacy check is what refuses them, before anything is written.
    assert {:ok, %HumanTask{}} = Ash.get(HumanTask, ctx.task.id, opts(reader.actor, ctx.tenant))

    for action <- [:approve, :reject] do
      assert {:error, %Ash.Error.Forbidden{}} =
               decide(ctx.task, action, reader.actor, ctx.tenant)
    end

    assert_still_open(ctx)
  end

  test "a candidate for their own task cannot decide another person's", ctx do
    member = member!(ctx, "Candidate elsewhere", [])
    _own_brief = brief!(member)
    member_actor = actor(member.user)
    [own_task] = awaiting(member_actor, ctx.tenant)
    refute own_task.id == ctx.task.id

    # Their live task lets them run the decision actions at all; the task itself is
    # not theirs to read, so the decision finds nothing to decide.
    for action <- [:approve, :reject] do
      assert_not_found(decide(ctx.task, action, member_actor, ctx.tenant), ctx.task)
    end

    assert_still_open(ctx)
  end

  test "a candidate in another tenant cannot decide this tenant's task", ctx do
    other = tenant!()
    _their_brief = brief!(other)
    outsider = actor(other.user)
    assert [_their_task] = awaiting(outsider, other.tenant)

    for action <- [:approve, :reject] do
      # Under their own tenant their live task admits them, and this tenant's task is
      # not in it.
      assert_not_found(decide(ctx.task, action, outsider, other.tenant), ctx.task)

      # Under this tenant they hold no task and no grant, so no policy admits them.
      assert {:error, %Ash.Error.Forbidden{}} = decide(ctx.task, action, outsider, ctx.tenant)
    end

    assert_still_open(ctx)
  end

  # A task the actor cannot read is refused as not found, which is this code's convention
  # for a row outside the actor's reach: it does not confirm that the task exists.
  defp assert_not_found(result, task) do
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{primary_key: key}]}} =
             result

    assert key == %{id: task.id}
  end

  defp assert_still_open(ctx) do
    assert %{status: :pending_approval} = reload_brief!(ctx.brief, ctx.tenant)
    assert [%{id: id, status: :open}] = awaiting(actor(ctx.user), ctx.tenant)
    assert id == ctx.task.id
  end

  defp awaiting(actor, tenant) do
    HumanTask |> Ash.Query.for_read(:awaiting_me, %{}, opts(actor, tenant)) |> Ash.read!()
  end

  defp decide(task, action, actor, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: task.id}, opts(actor, tenant))
    |> Ash.run_action()
  end

  defp can_decide?(task, action, actor, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: task.id}, opts(actor, tenant))
    |> Ash.can?(actor, tenant: tenant)
  end

  defp opts(actor, tenant), do: [actor: actor, tenant: tenant]
end
