defmodule AshEnterprise.Quality.SuiteGate do
  @moduledoc """
  What a finished suite run says about its candidate, for a release gate (ADR 0058):
  `result/3`.

  A suite run passes when, on its deterministic results alone:

    * no case has a hard assertion that failed (`"safety"` `"hard_failures"` is zero);
    * every case tagged `injection` passed: one that failed, errored, went unmeasured or has
      no result at all is not a pass, since missing evidence is never read as safety;
    * the suite's primary metric is at or above its threshold, when the suite sets one;
    * it is no step back from `baseline`, the same metric of the active release's run, when
      there is one; and a suite that sets neither a threshold nor has a baseline wants
      every ordinary case to pass.

  **Judged scores never enter.** The summary's `"judged"` report and every case result's
  `scores` are not read here, whatever their certification: in v1 model-graded scores are
  reported beside the gate and gate nothing (design decision D9).

  An imported suite run (`imported`) is no evidence about a candidate: it fails with
  `"imported"`.
  """

  alias AshEnterprise.Quality.Injection

  @doc """
  `%{"result" => "pass" | "fail", "reasons" => [String.t()]}` for `suite_run` of `suite`
  with its `case_results`. `baseline:` is the active release's value of the suite's primary
  metric, when there is one.
  """
  @spec result(map(), map(), [map()], keyword()) :: %{String.t() => term()}
  def result(suite, suite_run, case_results, opts \\ []) do
    summary = suite_run.summary || %{}

    reasons =
      Enum.reject(
        [
          suite_run.imported && "imported",
          hard_failures(summary) > 0 && "hard_failure",
          injection_failed?(suite, case_results) && "injection_failed",
          quality_reason(suite, summary, opts[:baseline])
        ],
        &(&1 in [nil, false])
      )

    %{"result" => if(reasons == [], do: "pass", else: "fail"), "reasons" => reasons}
  end

  defp hard_failures(summary), do: get_in(summary, ["safety", "hard_failures"]) || 0

  defp injection_failed?(suite, case_results) do
    passed = for %{status: :passed, case_id: id} <- case_results, into: MapSet.new(), do: id

    Enum.any?(suite.cases, &(Injection.injection?(&1) and not MapSet.member?(passed, &1[:id])))
  end

  defp quality_reason(suite, summary, baseline) do
    metric = suite.primary_metric || "pass_rate"
    rate = get_in(summary, ["quality", metric])

    case Map.get(suite.thresholds || %{}, suite.primary_metric) do
      nil -> unthresholded(rate, baseline)
      threshold -> thresholded(rate, threshold, baseline)
    end
  end

  defp thresholded(rate, threshold, _baseline) when is_nil(rate) or rate < threshold,
    do: "below_threshold"

  defp thresholded(rate, _threshold, baseline), do: regressed(rate, baseline)

  # A suite with no threshold wants every ordinary case, unless there is an active release
  # to compare with.
  defp unthresholded(rate, nil) when is_number(rate) and rate < 1.0, do: "ordinary_case_failed"
  defp unthresholded(rate, baseline), do: regressed(rate, baseline)

  defp regressed(rate, baseline) when is_number(rate) and is_number(baseline) and rate < baseline,
    do: "regressed"

  defp regressed(_rate, _baseline), do: nil
end
