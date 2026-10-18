defmodule AshEnterprise.Canonical.Actions.CompleteOwnTask do
  @moduledoc """
  `Task.complete_mine`: marks one of the actor's own tasks done.

  The row is found through `Task.mine` **as the actor** (`authorize?: true`),
  which filters on `owner_id == actor`, so another person's task — whatever
  roles the actor holds — is "not found" rather than reachable. Only then is
  `Task.complete` run on it, with the actor named on the write (provenance
  and the audit entry are theirs). That update is not authorized again: the
  self-service declaration is the grant, and it is bounded by the lookup
  above, which is the reason this is a generic action at all (ADR 0052 allows
  no self-service update).
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Canonical.Task

  @impl true
  def run(input, _opts, context) do
    opts = context |> Ash.Context.to_opts() |> Keyword.take([:actor, :tenant, :tracer])
    task_id = input.arguments.task_id

    Task
    |> Ash.Query.for_read(:mine, %{}, opts)
    |> Ash.Query.filter(id == ^task_id)
    |> Ash.read_one(Keyword.put(opts, :authorize?, true))
    |> case do
      {:ok, %Task{} = task} ->
        task
        |> Ash.Changeset.for_update(:complete, %{}, opts)
        |> Ash.update(Keyword.put(opts, :authorize?, false))

      {:ok, nil} ->
        {:error, Ash.Error.Query.NotFound.exception(resource: Task, primary_key: task_id)}

      {:error, error} ->
        {:error, error}
    end
  end
end
