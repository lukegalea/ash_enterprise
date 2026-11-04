defmodule AshEnterprise.Acp.ApprovalsTest do
  @moduledoc """
  The approval binding rule (ADR 0015 seam, ADR 0055): a prompt's permission
  request is an invocation the session's person owns, and a resolution decides
  only that. A foreign person's ref, an unknown one or one already decided
  approves nothing, even with `allow_once`; `reject_once` rejects the request;
  an option that was not offered decides nothing; a surface click's ref answers
  only in its own session.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Acp.{Approvals, SessionStore}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.SystemActor

  @allow %{"outcome" => "selected", "optionId" => "allow_once"}
  @reject %{"outcome" => "selected", "optionId" => "reject_once"}
  @always %{"outcome" => "selected", "optionId" => "allow_always"}

  setup do
    ctx = tenant!()
    brief!(ctx)
    task = open_task!(ctx)
    %{ctx: ctx, task: task}
  end

  test "the owner's allow_once approves their request", %{ctx: ctx, task: task} do
    session = session(ctx)
    {:pending, ref} = Approvals.request(session, spec(ctx, task), inputs(ctx, task))

    assert {:approved, %{"invocation_id" => ^ref}} = Approvals.resolve(ref, @allow, session)
    assert %{status: :awaiting_approval} = row(ref, ctx)
  end

  test "another person's session cannot answer the request", %{ctx: ctx, task: task} do
    owner = session(ctx)
    {:pending, ref} = Approvals.request(owner, spec(ctx, task), inputs(ctx, task))

    stranger = session(member!(ctx, "Stranger", []))
    assert {:denied} = Approvals.resolve(ref, @allow, stranger)
    assert {:denied} = Approvals.resolve(ref, @reject, stranger)

    assert %{status: :awaiting_approval} = row(ref, ctx)
    assert {:approved, _} = Approvals.resolve(ref, @allow, owner)
  end

  test "reject_once rejects the request, and nothing then approves it",
       %{ctx: ctx, task: task} do
    session = session(ctx)
    {:pending, ref} = Approvals.request(session, spec(ctx, task), inputs(ctx, task))

    assert {:denied} = Approvals.resolve(ref, @reject, session)
    assert %{status: :rejected} = row(ref, ctx)
    assert {:denied} = Approvals.resolve(ref, @allow, session)
  end

  test "an option that was not offered, or a cancel, decides nothing", %{ctx: ctx, task: task} do
    session = session(ctx)
    {:pending, ref} = Approvals.request(session, spec(ctx, task), inputs(ctx, task))

    assert {:denied} = Approvals.resolve(ref, @always, session)
    assert {:denied} = Approvals.resolve(ref, %{"outcome" => "cancelled"}, session)
    assert %{status: :awaiting_approval} = row(ref, ctx)
  end

  test "an unknown ref, or one this module never issued, is denied", %{ctx: ctx} do
    session = session(ctx)

    assert {:denied} = Approvals.resolve(Ash.UUID.generate(), @allow, session)
    assert {:denied} = Approvals.resolve("not-a-uuid", @allow, session)
    assert {:denied} = Approvals.resolve({:not_issued, Invocation, :confirm}, @allow, session)
  end

  test "a declared approval routed around its invocation is refused", %{ctx: ctx, task: task} do
    spec = %{resource: AshEnterprise.Bpmn.HumanTask, action: :approve, title: "Approve"}
    assert {:denied} = Approvals.request(session(ctx), spec, %{record_id: task.id})
  end

  test "a read whose declaration does not ask runs at once", %{ctx: ctx} do
    spec = %{resource: AshEnterprise.Accounts.BusinessUnit, action: :read, title: "List"}
    assert {:approved, %{auto: :no_approval}} = Approvals.request(session(ctx), spec, %{})
  end

  test "a surface click's confirmation answers only in its own session", %{ctx: ctx} do
    session = session(ctx)
    spec = %{resource: Invocation, action: :read, title: "Click", click: "Today"}

    assert {:pending, ref} = Approvals.request(session, spec, %{})
    assert {:denied} = Approvals.resolve(ref, @allow, session(ctx))
    assert {:denied} = Approvals.resolve(ref, @reject, session)
    assert {:approved, nil} = Approvals.resolve(ref, @allow, session)
  end

  # -- helpers ------------------------------------------------------------------

  defp session(ctx) do
    {:ok, session} = SessionStore.create(%{"actor" => ctx.actor})
    session
  end

  defp open_task!(%{tenant: tenant}) do
    AshEnterprise.Bpmn.HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.find(&(&1.status == :open))
  end

  defp inputs(ctx, task) do
    target = "AshEnterprise.Bpmn.HumanTask.approve"
    args = %{"record_id" => task.id}
    %{target: target, args: args, key: Approvals.key(ctx.actor, target, args, ctx.tenant)}
  end

  defp spec(ctx, _task),
    do: %{resource: Invocation, action: :confirm, title: "Approve", tenant: ctx.tenant}

  defp row(id, ctx),
    do: Execution.get_invocation!(id, actor: SystemActor.oban(), tenant: ctx.tenant)
end
