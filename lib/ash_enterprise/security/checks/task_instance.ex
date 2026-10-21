defmodule AshEnterprise.Security.Checks.TaskInstance do
  @moduledoc """
  A grant path for process runs: **being asked to decide a step lets you see
  where that run stands.**

  Reads the actor's precomputed `AshEnterprise.Security.ActorContext`
  `task_instance_ids` — the instances of the live tasks they (or one of their
  teams) are a candidate for, or hold — the same set
  `AshEnterprise.Security.Checks.TaskCandidacy` grants the tasks themselves
  from. It is what a flight view needs to draw that run with its token on the
  step waiting for them.

    * On `AshEnterprise.Bpmn.Instance` (`field: :id`): reads of those runs.
    * On `AshEnterprise.Bpmn.Token` (`field: :instance_id`): reads of their
      tokens.

  Reads only: no create, update, destroy or generic action, so it cannot move
  a run or act on one. A run's subject is not reached through it either — a
  surface that names the subject reads it under the subject's own policies.
  Someone who also holds a role grant keeps everything that grant reaches;
  someone with neither reaches nothing. The set follows the live work: once
  the task is decided the run leaves it, exactly as the task does.

  ## Never queries

  `task_instance_ids` is loaded with `task_ids`, in the same query, when the
  context is built; the grant is an `IN (...)` filter.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext

  require Ash.Expr
  import Ash.Expr, only: [expr: 1, ref: 1]

  @impl true
  def describe(opts) do
    "the record belongs to a process run with a step the actor is a candidate for, or holds " <>
      "(#{inspect(Keyword.get(opts, :field, :id))})"
  end

  @impl true
  def filter(actor, authorizer, opts) do
    context = ActorContext.for_actor(actor)
    field = Keyword.get(opts, :field, :id)

    cond do
      context.system? -> false
      is_nil(context.user_id) -> false
      context.task_instance_ids == [] -> false
      authorizer.action.type == :read -> expr(^ref(field) in ^context.task_instance_ids)
      true -> false
    end
  end
end
