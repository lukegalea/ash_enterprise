defmodule AshEnterprise.Quality.Changes.Finish do
  @moduledoc """
  A suite run's `finish`: scores each case's agent run with the deterministic scorer
  (`AshEnterprise.Quality.Assertions`), records one `AshEnterprise.Quality.CaseResult`
  per case in the same transaction, and sets the `summary`.

  A case's run is finished once it is no longer queued, running or waiting on its tools:
  a run waiting on a person, its budget or a limit waits for someone to act, which an
  evaluation never does, so it is scored as it stands (`errored`, unless an assertion
  failed).

  What a case's run recorded is read without authorization, as the job runner reads
  it: the run, the names of every tool its model called (its steps' `tool_calls`), its
  invocations with their arguments, and its answer. A suite run with a case whose run
  has not finished is refused.

  The summary keeps quality and safety apart (ADR 0058):

    * `"quality"`: `cases`, `passed`, `failed`, `errored`, `unmeasured` and `pass_rate`
      (passed over all cases);
    * `"safety"`: `hard_failures` (cases with a hard assertion that failed) and
      `prohibited_effect_hits`.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality.{Assertions, CaseResult, Suite, SuiteRun}

  @epoch 1

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&score/1)
    |> Ash.Changeset.after_action(&record/2)
  end

  defp score(changeset) do
    suite_run = changeset.data
    tenant = changeset.tenant
    suite = Ash.get!(Suite, suite_run.suite_id, authorize?: false, tenant: tenant)
    runs = runs(suite_run, suite, tenant)

    if Enum.any?(Map.values(runs), &open?/1) do
      Ash.Changeset.add_error(changeset, field: :status, message: "its cases are still running")
    else
      results = Enum.map(suite.cases, &result(&1, Map.get(runs, &1[:id]), tenant))

      changeset
      |> Ash.Changeset.force_change_attributes(%{
        summary: summary(results),
        finished_at: DateTime.utc_now()
      })
      |> Ash.Changeset.set_context(%{quality: %{results: results}})
    end
  end

  defp record(changeset, suite_run) do
    opts = [
      actor: SystemActor.oban(),
      tenant: changeset.tenant,
      context: %{quality: %{suite_run: suite_run}}
    ]

    changeset.context.quality.results
    |> Enum.reduce_while({:ok, suite_run}, fn attrs, ok ->
      case Ash.create(
             CaseResult,
             Map.put(attrs, :suite_run_id, suite_run.id),
             [action: :record] ++ opts
           ) do
        {:ok, _result} -> {:cont, ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp runs(suite_run, suite, tenant) do
    keys = Map.new(suite.cases, &{SuiteRun.run_key(suite_run.id, &1[:id], @epoch), &1[:id]})
    run_keys = Map.keys(keys)

    Execution.list_agent_runs!(
      query: [filter: [run_key: [in: run_keys]]],
      load: [:output],
      authorize?: false,
      tenant: tenant
    )
    |> Map.new(&{Map.fetch!(keys, &1.run_key), &1})
  end

  # A run waiting on its tools is still going; one waiting on a person, its budget or a
  # limit waits for someone to act, which an evaluation never does, so it is scored as
  # it stands.
  defp open?(%{status: status}) when status in [:queued, :running], do: true
  defp open?(%{status: :waiting, blocked_on: :tools}), do: true
  defp open?(_run), do: false

  defp result(c, nil, _tenant) do
    %{case_id: c[:id], epoch: @epoch, status: :errored, assertion_results: [], run_id: nil}
  end

  defp result(c, run, tenant) do
    observed = observe(run, tenant)
    assertion_results = Enum.map(c[:assertions] || [], &Assertions.evaluate(&1, observed))

    %{
      case_id: c[:id],
      epoch: @epoch,
      status: status(assertion_results, run),
      assertion_results: assertion_results,
      prohibited_effect_hit:
        Enum.any?(
          assertion_results,
          &(&1["type"] == "prohibited_effect" and &1["status"] == "failed")
        ),
      run_id: run.id
    }
  end

  defp status(results, run) do
    statuses = Enum.map(results, & &1["status"])

    cond do
      "failed" in statuses -> :failed
      run.status != :completed -> :errored
      "passed" not in statuses -> :unmeasured
      true -> :passed
    end
  end

  defp observe(run, tenant) do
    opts = [authorize?: false, tenant: tenant]
    id = run.id

    steps = Execution.list_agent_steps!([query: [filter: [run_id: id]]] ++ opts)

    invocations =
      Execution.list_invocations!([query: [filter: [run_id: id]], load: [:args]] ++ opts)

    %{
      run: run,
      tool_names: MapSet.new(for step <- steps, call <- step.tool_calls || [], do: call["name"]),
      invocations: Enum.map(invocations, &Map.take(&1, [:target, :args, :approval_mode])),
      answer: answer(run.output)
    }
  end

  defp answer(%{"value" => value}), do: value
  defp answer(_none), do: nil

  defp summary(results) do
    count = fn status -> Enum.count(results, &(&1.status == status)) end
    cases = length(results)

    hard_failures =
      Enum.count(results, fn result ->
        Enum.any?(result.assertion_results, &(&1["hard"] and &1["status"] == "failed"))
      end)

    %{
      "quality" => %{
        "cases" => cases,
        "passed" => count.(:passed),
        "failed" => count.(:failed),
        "errored" => count.(:errored),
        "unmeasured" => count.(:unmeasured),
        "pass_rate" => if(cases == 0, do: 0.0, else: count.(:passed) / cases)
      },
      "safety" => %{
        "hard_failures" => hard_failures,
        "prohibited_effect_hits" => Enum.count(results, & &1[:prohibited_effect_hit])
      }
    }
  end
end
