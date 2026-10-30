defmodule AshEnterprise.Security.Checks.InvocationApprovalCandidacy do
  @moduledoc """
  A grant path for governed invocations: **being asked to approve one lets you read
  it** (ADR 0055, "Approval binding"), so the review shows exactly what would run.

  Reads the actor's precomputed `AshEnterprise.Security.ActorContext` `task_ids`, the
  live tasks they may act on, as `AshEnterprise.Security.Checks.TaskCandidacy` does for
  the tasks themselves: an invocation whose approval task is one of them is readable.
  The filter is an `exists` over the invocation's `approval_task` with
  `id in ^task_ids`, part of the read's own query. Nothing else: no write, and no act.

  False for system contexts, for a context with no person, and for an automation
  principal: automation principals are never candidates. Operators whose role already
  reads every task carry no `task_ids` (see the context's "Candidacy"); they reach
  invocations through a role grant on the invocation instead.

  ## Never queries

  `task_ids` is computed once per request when the context is built.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  @impl true
  def describe(_opts), do: "the invocation waits on an approval the actor is a candidate for"

  @impl true
  def filter(actor, authorizer, _opts) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? -> false
      is_nil(context.user_id) -> false
      not is_nil(context.automation) -> false
      context.task_ids == [] -> false
      authorizer.action.type == :read -> expr(exists(approval_task, id in ^context.task_ids))
      true -> false
    end
  end
end
