defmodule AshEnterprise.Security.Checks.TaskCandidacy do
  @moduledoc """
  A grant path for human tasks: **being asked to act on a task lets you see
  it and act on it.**

  Reads the actor's precomputed `AshEnterprise.Security.ActorContext`
  `task_ids` — open tasks they (or one of their teams) are a candidate for,
  and claimed tasks they hold, minus any whose maker-checker exclusions name
  them. The set comes from the process engine's own candidacy read, so the
  tasks it reaches are exactly the ones the engine would let the person claim,
  complete or receive by delegation.

    * **Reads** of those tasks: `id in task_ids`.
    * **The acts** the resource lists in `acts:` (generic actions such as
      claim, complete, delegate, approve, reject), for an actor with at least
      one live task. A generic action names no row, so the grant cannot be
      narrower than that; each act reads its task as the actor (through the
      read grant above) and the engine checks candidacy for that task before
      it writes, so passing here is never enough on its own to decide
      anything.

  Nothing else: no create, update or destroy (the engine's `:claim`,
  `:complete` and `:delegate` refuse every caller but the engine anyway).

  Declared on the resource that needs it (`extra_grants:` on
  `AshEnterprise.Platform.Resource`; only `AshEnterprise.Bpmn.HumanTask`), and
  appended to the inherited union there, so it only ever adds. Someone who
  also holds a role grant on tasks keeps everything that grant reaches; someone
  with neither reaches nothing. Maker-checker stays the engine's subtraction at
  candidate resolution — the excluded requester has no candidate row and the
  engine's read leaves out a task that names them — never a `forbid_if`.

  ## Never queries

  `task_ids` is computed once per request when the context is built; the read
  grant is an `id in [...]` filter, like `SharedWithActor`. The list grows with
  a person's live work, not with their history: a decided task leaves it.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  @impl true
  def describe(opts) do
    case Keyword.get(opts, :acts, []) do
      [] ->
        "the task is one the actor (or one of their teams) is a candidate for, or holds"

      acts ->
        "the task is one the actor is a candidate for or holds; " <>
          "#{Enum.map_join(acts, ", ", &inspect/1)} for an actor with a live task"
    end
  end

  @impl true
  def filter(actor, authorizer, opts) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? -> false
      is_nil(context.user_id) -> false
      context.task_ids == [] -> false
      authorizer.action.type == :read -> expr(id in ^context.task_ids)
      authorizer.action.type == :action -> authorizer.action.name in Keyword.get(opts, :acts, [])
      true -> false
    end
  end
end
