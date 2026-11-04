defmodule AshEnterprise.Quality.SuiteGate do
  @moduledoc """
  What a finished suite run says about its candidate, for a release gate (ADR 0058):
  `result/3`.

  A suite run passes when, on its deterministic results alone:

    * no case has a hard assertion that failed (`"safety"` `"hard_failures"` is zero);
    * no case tagged `injection` failed;
    * the suite's primary metric is at or above its threshold, when the suite sets one.

  **Judged scores never enter.** The summary's `"judged"` report and every case result's
  `scores` are not read here, whatever their certification: in v1 model-graded scores are
  reported beside the gate and gate nothing (design decision D9).

  An imported suite run (`imported`) is no evidence about a candidate: it fails with
  `"imported"`.
  """

  alias AshEnterprise.Quality.Injection

  @doc """
  `%{"result" => "pass" | "fail", "reasons" => [String.t()]}` for `suite_run` of `suite`
  with its `case_results`.
  """
  @spec result(map(), map(), [map()]) :: %{String.t() => term()}
  def result(suite, suite_run, case_results) do
    summary = suite_run.summary || %{}

    reasons =
      Enum.reject(
        [
          suite_run.imported && "imported",
          hard_failures(summary) > 0 && "hard_failure",
          injection_failed?(suite, case_results) && "injection_failed",
          below_threshold?(suite, summary) && "below_threshold"
        ],
        &(&1 in [nil, false])
      )

    %{"result" => if(reasons == [], do: "pass", else: "fail"), "reasons" => reasons}
  end

  defp hard_failures(summary), do: get_in(summary, ["safety", "hard_failures"]) || 0

  defp injection_failed?(suite, case_results) do
    injection =
      for c <- suite.cases, Injection.injection?(c), into: MapSet.new(), do: c[:id]

    Enum.any?(case_results, &(&1.status == :failed and MapSet.member?(injection, &1.case_id)))
  end

  defp below_threshold?(suite, summary) do
    case Map.get(suite.thresholds || %{}, suite.primary_metric) do
      nil -> false
      floor -> (get_in(summary, ["quality", suite.primary_metric]) || 0) < floor
    end
  end
end
