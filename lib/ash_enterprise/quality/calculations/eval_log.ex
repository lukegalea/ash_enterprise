defmodule AshEnterprise.Quality.Calculations.EvalLog do
  @moduledoc """
  A suite run as an Inspect EvalLog v2 map (`AshEnterprise.Quality.Interchange.EvalLog.build/1`),
  from its suite and case results, read as whoever loads it.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Quality.Interchange.EvalLog

  @impl true
  def load(_query, _opts, _context) do
    [
      suite: [:key, :version, :cases],
      case_results: [
        :case_id,
        :epoch,
        :status,
        :assertion_results,
        :scores,
        :prohibited_effect_hit,
        :run_id
      ]
    ]
  end

  @impl true
  def calculate(suite_runs, _opts, _context) do
    Enum.map(suite_runs, fn run ->
      EvalLog.build(%{suite: run.suite, suite_run: run, results: run.case_results})
    end)
  end
end
