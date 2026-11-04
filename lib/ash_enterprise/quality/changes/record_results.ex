defmodule AshEnterprise.Quality.Changes.RecordResults do
  @moduledoc """
  Writes a suite run's case results, in the transaction that finishes or imports it:
  one `AshEnterprise.Quality.CaseResult` per entry of `results`, as the job runner, with
  the suite run in the context that lets `record` take its owner from it.
  """

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality.CaseResult

  @doc "Records `results` for `suite_run`: `{:ok, suite_run}`, or the first `{:error, error}`."
  @spec record(map(), [map()], term()) :: {:ok, map()} | {:error, term()}
  def record(suite_run, results, tenant) do
    opts = [
      action: :record,
      actor: SystemActor.oban(),
      tenant: tenant,
      context: %{quality: %{suite_run: suite_run}}
    ]

    Enum.reduce_while(results, {:ok, suite_run}, fn attrs, ok ->
      case Ash.create(CaseResult, Map.put(attrs, :suite_run_id, suite_run.id), opts) do
        {:ok, _result} -> {:cont, ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
