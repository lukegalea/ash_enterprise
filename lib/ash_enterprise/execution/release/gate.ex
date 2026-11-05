defmodule AshEnterprise.Execution.Release.Gate do
  @moduledoc """
  The release gate (ADR 0058, PLAT-09): what a candidate manifest must show before anyone is
  asked to approve it.

  `check/2` returns the gate's result, a map of string keys that is kept on the manifest
  (`gate_result`) and becomes the predicate of its attestation:

      %{
        "passed" => false,
        "problems" => ["suite clinic.injection: 1 injection case failed (…)"],
        "suites" => [%{"name" => "clinic.injection", "suite_run_id" => "…", …}],
        "checked_at" => "…"
      }

  A manifest passes only when all of these hold:

    * every entry still resolves, is published where it has to be and has the digest it was
      resolved with (`AshEnterprise.Execution.Release.Entries.problems/2`);
    * a manifest that pins an agent also pins a suite: an agent is released on what a suite
      measured, so no suite is no measurement;
    * for each suite entry there is a finished `:offline` suite run on exactly this manifest
      (`release_manifest_id` and `candidate_digest`, the manifest's digest) of exactly this
      version of the suite (its content hash), which `AshEnterprise.Quality.SuiteGate`
      passes: no hard failure, whatever the averages say; every injection case passed; the
      suite's primary metric at or above its threshold, when the suite sets one, and no step
      back from the same release's predecessor (the active manifest of its key); a suite
      with neither wants every ordinary case to pass;
    * every agent entry was measured: some of those runs ran exactly the agent version the
      entry pins, so a release of several agents is not carried by the measurement of one.

  Only deterministic scorers gate (`SuiteGate` never reads a judged score). A run in another
  mode (`:adhoc` experiments, `:shadow` comparisons) is never looked at: an adhoc run
  measures a version nobody approved. Nor is an imported run, which names no candidate.
  """

  require Ash.Query

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Release.Entries
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{SuiteGate, SuiteRun}

  @doc "The gate's result for `manifest` (a resolved one) in `tenant`."
  @spec check(map(), Ash.UUID.t()) :: map()
  def check(manifest, tenant) do
    entries = manifest.entries
    suites = for %{"annotations" => %{"kind" => "suite"}} = entry <- entries, do: entry

    {suite_results, suite_problems} =
      suites
      |> Enum.map(&suite(&1, manifest, tenant))
      |> Enum.unzip()

    problems =
      Entries.problems(entries, tenant) ++
        agent_needs_suite(entries, suites) ++
        agents_measured(entries, suite_results) ++ List.flatten(suite_problems)

    %{
      "passed" => problems == [],
      "problems" => problems,
      "suites" => suite_results,
      "checked_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  @doc "The ids of the suite runs a gate result rests on."
  @spec suite_run_ids(map()) :: [Ash.UUID.t()]
  def suite_run_ids(%{"suites" => suites}),
    do: for(%{"suite_run_id" => id} when is_binary(id) <- suites, do: id)

  defp agent_needs_suite(entries, suites) do
    agent? = Enum.any?(entries, &(&1["annotations"]["kind"] == "agent"))

    if agent? and suites == [],
      do: ["an agent is released on what a suite measured: pin a suite"],
      else: []
  end

  # With no suite pinned, `agent_needs_suite/2` already says so.
  defp agents_measured(_entries, []), do: []

  defp agents_measured(entries, suite_results) do
    measured = for %{"agent_version_id" => id} when is_binary(id) <- suite_results, do: id

    for %{"annotations" => %{"kind" => "agent", "id" => id}} = entry <- entries,
        id not in measured,
        do: "agent #{entry["name"]}: no suite run measured this version"
  end

  defp suite(entry, manifest, tenant) do
    name = entry["name"]
    suite_id = entry["annotations"]["id"]

    case latest_run(manifest, suite_id, tenant) do
      nil ->
        {%{"name" => name, "suite_run_id" => nil},
         ["suite #{name}: no finished offline run on this manifest"]}

      run ->
        suite = Quality.get_suite!(suite_id, authorize?: false, tenant: tenant)

        case_results =
          Quality.list_case_results!(
            query: [filter: [suite_run_id: run.id]],
            authorize?: false,
            tenant: tenant
          )

        %{"result" => result, "reasons" => reasons} =
          SuiteGate.result(suite, run, case_results,
            baseline: baseline(manifest, name, suite, tenant)
          )

        problems =
          [
            run.suite_content_hash != entry["digest"]["sha256"] &&
              "the run measured other cases than the suite pins"
          ]
          |> Enum.filter(&is_binary/1)
          |> Kernel.++(Enum.map(reasons, &reason(&1, run, suite)))
          |> Enum.map(&"suite #{name}: #{&1}")

        {%{
           "name" => name,
           "suite_run_id" => run.id,
           "agent_version_id" => run.agent_version_id,
           "result" => result,
           "reasons" => reasons
         }, problems}
    end
  end

  # The newest finished offline run of this suite on exactly this manifest. An imported
  # run names no candidate and is never one.
  defp latest_run(manifest, suite_id, tenant) do
    SuiteRun
    |> Ash.Query.filter(
      release_manifest_id == ^manifest.id and candidate_digest == ^manifest.manifest_digest and
        suite_id == ^suite_id and mode == :offline and status == :finished and imported == false
    )
    |> Ash.Query.sort(finished_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  # The suite's primary metric in the run the active release of this manifest's key rests on,
  # for the suite of the same name: what a candidate must not fall below.
  defp baseline(manifest, name, suite, tenant) do
    with %{} = active <-
           [authorize?: false, tenant: tenant]
           |> Execution.active_release_manifests!()
           |> Enum.find(&(&1.key == manifest.key and &1.id != manifest.id)),
         %{"suite_run_id" => id} when is_binary(id) <-
           Enum.find(active.gate_result["suites"] || [], &(&1["name"] == name)),
         %{} = run <- Ash.get!(SuiteRun, id, authorize?: false, tenant: tenant) do
      get_in(run.summary, ["quality", suite.primary_metric || "pass_rate"])
    else
      _none -> nil
    end
  end

  defp reason("hard_failure", run, _suite),
    do: "#{get_in(run.summary, ["safety", "hard_failures"])} hard failure(s)"

  defp reason("injection_failed", run, _suite),
    do: "injection case(s) failed (#{failed_cases(run.summary)})"

  defp reason("ordinary_case_failed", run, suite) do
    "ordinary case(s) failed, #{suite.primary_metric || "pass_rate"} " <>
      "#{inspect(get_in(run.summary, ["quality", suite.primary_metric || "pass_rate"]))}"
  end

  defp reason("regressed", run, suite) do
    "#{suite.primary_metric || "pass_rate"} " <>
      "#{inspect(get_in(run.summary, ["quality", suite.primary_metric || "pass_rate"]))} " <>
      "is a step back from the active release"
  end

  defp reason("below_threshold", run, suite) do
    "#{suite.primary_metric} #{inspect(get_in(run.summary, ["quality", suite.primary_metric]))} " <>
      "is below #{suite.thresholds[suite.primary_metric]}"
  end

  defp reason(other, _run, _suite), do: other

  defp failed_cases(summary),
    do: summary |> get_in(["injection", "failed_cases"]) |> List.wrap() |> Enum.join(", ")
end
