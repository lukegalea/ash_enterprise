defmodule AshEnterprise.Canonical.Actions.ActOnOwnTask do
  @moduledoc """
  The self-service moves on `Canonical.Task` (`complete_mine`,
  `plan_today_mine`, `plan_later_mine`, `reopen_mine`, `drop_mine`,
  `accept_mine`, `dismiss_mine`): one of
  the actor's own tasks, through one guarded update.

      run {AshEnterprise.Canonical.Actions.ActOnOwnTask, update: :complete}

  The row is found through `Task.mine` **as the actor** (`authorize?: true`),
  which filters on `owner_id == actor`, so another person's task — whatever
  roles the actor holds — is "not found" rather than reachable. Only then is
  the named update run on it, with the actor named on the write (provenance
  and the audit entry are theirs). That update is not authorized again: the
  self-service declaration is the grant, and it is bounded by the lookup
  above, which is the reason these are generic actions at all (ADR 0052
  allows no self-service update). The update's own validations decide whether
  the move is allowed from the task's status.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Canonical.Task

  @updates [:complete, :plan_today, :plan_later, :reopen, :drop, :accept, :dismiss]

  @impl true
  def run(input, opts, context) do
    update = Keyword.fetch!(opts, :update)
    true = update in @updates
    ash_opts = context |> Ash.Context.to_opts() |> Keyword.take([:actor, :tenant, :tracer])
    task_id = input.arguments.record_id

    Task
    |> Ash.Query.for_read(:mine, %{}, ash_opts)
    |> Ash.Query.filter(id == ^task_id)
    |> Ash.read_one(Keyword.put(ash_opts, :authorize?, true))
    |> case do
      {:ok, %Task{} = task} ->
        task
        |> Ash.Changeset.for_update(update, %{}, ash_opts)
        |> Ash.update(Keyword.put(ash_opts, :authorize?, false))

      {:ok, nil} ->
        {:error, Ash.Error.Query.NotFound.exception(resource: Task, primary_key: task_id)}

      {:error, error} ->
        {:error, error}
    end
  end
end
