defmodule AshEnterprise.Assistant.Actions.Unpin do
  @moduledoc """
  `PinnedApp.unpin`: removes one of the actor's own pinned apps.

  Found through `PinnedApp.mine` as the actor (`owner_id == actor`), so an id
  that is not theirs is "not found"; only then is `:remove` run, with the
  actor named on it. Same shape as `Canonical.Task.complete_mine`: ADR 0052
  allows no self-service destroy, so the bound is the lookup.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Assistant.PinnedApp

  @impl true
  def run(input, _opts, context) do
    opts = context |> Ash.Context.to_opts() |> Keyword.take([:actor, :tenant, :tracer])
    app_id = input.arguments.app_id

    PinnedApp
    |> Ash.Query.for_read(:mine, %{}, opts)
    |> Ash.Query.filter(id == ^app_id)
    |> Ash.read_one(Keyword.put(opts, :authorize?, true))
    |> case do
      {:ok, %PinnedApp{} = app} ->
        app
        |> Ash.Changeset.for_destroy(:remove, %{}, opts)
        |> Ash.destroy(Keyword.put(opts, :authorize?, false))

      {:ok, nil} ->
        {:error, Ash.Error.Query.NotFound.exception(resource: PinnedApp, primary_key: app_id)}

      {:error, error} ->
        {:error, error}
    end
  end
end
