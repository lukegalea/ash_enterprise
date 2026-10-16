defmodule AshEnterprise.Bpmn.Candidacy do
  @moduledoc """
  Who may act on a human task, answered from the materialised candidacy
  (manifesto 03) and the task's own assignee — the one place the surfaces'
  task actions ask it (`AshEnterprise.Bpmn.Actions.DecideTask`,
  `AshEnterprise.Bpmn.Actions.WorkTask`).

    * **candidate** — a `TaskCandidate` row names the actor or one of their
      teams (the actor's principal ids come from the precomputed
      `ActorContext`, never a query of their own).
    * **assignee** — the task is claimed by the actor: they claimed it, or
      it was delegated to them.

  `AshBpmn.complete_task/2` and the engine's own `:claim`/`:delegate`
  actions do not check either; these functions are the check, run inside
  the actions before the engine is called. They are action logic, not policy
  checks: the read they issue happens once per click, never per row.
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.TaskCandidate
  alias AshEnterprise.Security.ActorContext

  @doc "`:ok` when a candidate row names the actor or one of their teams, else `Forbidden`."
  @spec candidate(struct(), term(), keyword()) :: :ok | {:error, Exception.t()}
  def candidate(task, actor, opts) do
    principal_ids = ActorContext.for_actor(actor).principal_ids

    TaskCandidate
    |> Ash.Query.filter(task_id == ^task.id and principal_id in ^principal_ids)
    |> Ash.exists?(opts)
    |> if(do: :ok, else: {:error, Ash.Error.Forbidden.exception([])})
  end

  @doc "`:ok` when the task is claimed by the actor, else `Forbidden`."
  @spec assignee(struct(), term()) :: :ok | {:error, Exception.t()}
  def assignee(%{status: :claimed, assignee_type: :user, assignee_id: id}, %{id: id})
      when not is_nil(id),
      do: :ok

  def assignee(_task, _actor), do: {:error, Ash.Error.Forbidden.exception([])}

  @doc "`:ok` when the actor is the task's assignee or one of its candidates."
  @spec assignee_or_candidate(struct(), term(), keyword()) :: :ok | {:error, Exception.t()}
  def assignee_or_candidate(task, actor, opts) do
    case assignee(task, actor) do
      :ok -> :ok
      {:error, _not_assignee} -> candidate(task, actor, opts)
    end
  end
end
