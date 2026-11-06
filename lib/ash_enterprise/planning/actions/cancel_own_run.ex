defmodule AshEnterprise.Planning.Actions.CancelOwnRun do
  @moduledoc """
  The self-service `Run.cancel`: one of the actor's own runs, through one guarded update.

      run AshEnterprise.Planning.Actions.CancelOwnRun

  The run is found through `Run.mine` **as the actor** (`authorize?: true`), which filters
  on `owner_id == actor`, so another person's run, whatever roles the actor holds, is "not
  found" rather than reachable. Only then is `:request_cancel` run on it with reason
  `:requested`, named as the actor. That update is not authorized again: the self-service
  declaration is the grant and the lookup above is its bound, which is why this is a generic
  action at all (ADR 0052 allows no self-service update). An operator cancels through the
  `:request_cancel` update itself, under their grants.

  The update records the request; the solver session (or the lease sweep) ends the run.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Planning.Run

  @impl true
  def run(input, _opts, context) do
    ash_opts = context |> Ash.Context.to_opts() |> Keyword.take([:actor, :tenant, :tracer])
    run_id = input.arguments.run_id

    Run
    |> Ash.Query.for_read(:mine, %{}, ash_opts)
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.read_one(Keyword.put(ash_opts, :authorize?, true))
    |> case do
      {:ok, %Run{} = run} ->
        run
        |> Ash.Changeset.for_update(:request_cancel, %{reason: :requested}, ash_opts)
        |> Ash.update(Keyword.put(ash_opts, :authorize?, false))

      {:ok, nil} ->
        {:error, Ash.Error.Query.NotFound.exception(resource: Run, primary_key: run_id)}

      {:error, error} ->
        {:error, error}
    end
  end
end
