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
      (passed over all cases that are not injection cases);
    * `"safety"`: `hard_failures` (cases with a hard assertion that failed) and
      `prohibited_effect_hits`, over every case;
    * `"injection"`, only when the suite has injection cases: the lane of
      `AshEnterprise.Quality.Injection`;
    * `"provenance"`, for an `:adhoc` suite run only: what it tried and what that took
      (`AshEnterprise.Quality.Provenance`);
    * `"judged"`, only when the suite names a judged scorer: the family report of
      `AshEnterprise.Quality.JudgedScores`, and each case result's `scores`.

  ## Judged scores

  Each case's answer is the reply subject `"agent_reply:<suite run id>/<case id>/1"`
  (`AshEnterprise.Quality.AgentReply`'s `:from_run`, read as the job runner), and its
  judged scores are what the admitted facts say about it now
  (`AshEnterprise.Quality.Gate.family_report/3`). Nothing here asks a model: an answer
  no judge has graded reads `unknown` (`no_fact`), and a case with no text answer is
  an unknown reply too, never a pass. The scores report and never gate
  (ADR 0058, decision D9).
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality

  alias AshEnterprise.Quality.{
    Assertions,
    Gate,
    Injection,
    JudgedScores,
    Provenance,
    Suite,
    SuiteRun
  }

  alias AshEnterprise.Quality.Changes.RecordResults

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
      judged = judged(suite, suite_run, runs, tenant)

      results =
        Enum.map(suite.cases, fn c ->
          c
          |> result(Map.get(runs, c[:id]), tenant)
          |> Map.put(:scores, Map.get(judged.scores, c[:id], []))
        end)

      finished_at = DateTime.utc_now()

      changeset
      |> Ash.Changeset.force_change_attributes(%{
        summary:
          suite.cases
          |> summary(results)
          |> provenance(suite_run, Map.values(runs), finished_at, tenant)
          |> put_judged(judged.report),
        finished_at: finished_at
      })
      |> Ash.Changeset.set_context(%{quality: %{results: results}})
    end
  end

  defp record(changeset, suite_run),
    do: RecordResults.record(suite_run, changeset.context.quality.results, changeset.tenant)

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
      status: Assertions.case_status(assertion_results, run.status == :completed),
      assertion_results: assertion_results,
      prohibited_effect_hit:
        Enum.any?(
          assertion_results,
          &(&1["type"] == "prohibited_effect" and &1["status"] == "failed")
        ),
      tainted: run.tainted?,
      run_id: run.id
    }
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

  # The families a suite names as judged scorers; `agent_reply_style` is the only one.
  defp judged(%{scorers: scorers} = suite, suite_run, runs, tenant) do
    if Enum.any?(scorers, &(&1["kind"] == "judged" and &1["family"] == "agent_reply_style")) do
      opts = [tenant: tenant, actor: SystemActor.oban()]
      replies = Enum.map(suite.cases, &reply(suite_run, &1[:id], Map.get(runs, &1[:id]), opts))
      JudgedScores.build(replies, Gate.family_report(replies, :agent_reply_style, opts), opts)
    else
      %{scores: %{}, report: nil}
    end
  end

  # The case's answer as a reply subject, or a stand-in with no text and no facts, so
  # the report reads it unknown.
  defp reply(suite_run, case_id, run, opts) do
    args = %{run_id: suite_run.id, case_id: case_id, epoch: @epoch}

    case run && Quality.reply_from_run(run.id, args, opts) do
      {:ok, %Quality.AgentReply{} = reply} ->
        reply

      _no_answer ->
        %{id: "agent_reply:#{suite_run.id}/#{case_id}/#{@epoch}", text: "", used_tools: false}
    end
  end

  defp put_judged(summary, nil), do: summary
  defp put_judged(summary, report), do: Map.put(summary, "judged", report)

  # An adhoc suite run says what it tried and what that took (`Quality.Provenance`).
  defp provenance(summary, %{mode: :adhoc} = suite_run, runs, finished_at, tenant) do
    version =
      Execution.get_agent_version!(suite_run.agent_version_id,
        authorize?: false,
        tenant: tenant
      )

    Map.put(summary, "provenance", Provenance.build(suite_run, version, runs, finished_at))
  end

  defp provenance(summary, _suite_run, _runs, _finished_at, _tenant), do: summary

  @doc """
  The summary of a suite run's case `results` (maps with `status`, `assertion_results` and
  `prohibited_effect_hit`) over the suite's cases: quality, safety and, when the suite has
  injection cases, the injection lane, as set at `finish`.
  """
  @spec summary([map()], [map()]) :: map()
  def summary(suite_cases, all_results) do
    injection_ids = for c <- suite_cases, Injection.injection?(c), do: c[:id]
    results = Enum.reject(all_results, &(&1.case_id in injection_ids))
    count = fn status -> Enum.count(results, &(&1.status == status)) end
    cases = length(results)

    hard_failures =
      Enum.count(all_results, fn result ->
        Enum.any?(result.assertion_results, &(&1["hard"] and &1["status"] == "failed"))
      end)

    summary = %{
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
        "prohibited_effect_hits" => Enum.count(all_results, & &1[:prohibited_effect_hit])
      }
    }

    case Injection.lane(suite_cases, all_results) do
      nil -> summary
      lane -> Map.put(summary, "injection", lane)
    end
  end
end
