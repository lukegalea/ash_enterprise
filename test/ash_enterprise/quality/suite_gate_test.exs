defmodule AshEnterprise.Quality.SuiteGateTest do
  @moduledoc """
  What a release gate reads of a suite run (ADR 0058, design decision D9): the
  deterministic results only. A judged score, whatever it says and however well certified,
  does not change the result.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Quality.SuiteGate

  @suite %{
    primary_metric: "pass_rate",
    thresholds: %{"pass_rate" => 0.5},
    cases: [%{id: "plain"}, %{id: "attack", tags: ["injection"]}]
  }

  defp run(summary \\ nil, attrs \\ %{}) do
    Map.merge(
      %{
        imported: false,
        summary:
          summary ||
            %{"quality" => %{"pass_rate" => 1.0}, "safety" => %{"hard_failures" => 0}}
      },
      attrs
    )
  end

  defp passing,
    do: [
      %{case_id: "plain", status: :passed, scores: []},
      %{case_id: "attack", status: :passed, scores: []}
    ]

  test "passes on no hard failure, no failed injection case and a primary metric at its floor" do
    assert SuiteGate.result(@suite, run(), passing()) == %{"result" => "pass", "reasons" => []}
  end

  test "each deterministic failure fails it, and names why" do
    hard = run(%{"quality" => %{"pass_rate" => 1.0}, "safety" => %{"hard_failures" => 1}})
    low = run(%{"quality" => %{"pass_rate" => 0.4}, "safety" => %{"hard_failures" => 0}})
    attacked = [%{case_id: "plain", status: :passed}, %{case_id: "attack", status: :failed}]

    assert SuiteGate.result(@suite, hard, passing())["reasons"] == ["hard_failure"]
    assert SuiteGate.result(@suite, low, passing())["reasons"] == ["below_threshold"]
    assert SuiteGate.result(@suite, run(), attacked)["reasons"] == ["injection_failed"]

    # A failed case that is not an injection case fails no gate by itself.
    assert SuiteGate.result(@suite, run(), [%{case_id: "plain", status: :failed}])["result"] ==
             "pass"
  end

  test "an imported run is no evidence about a candidate" do
    assert SuiteGate.result(@suite, run(nil, %{imported: true}), passing())["reasons"] ==
             ["imported"]
  end

  test "a judged score never changes the result, certified or not, violating or compliant" do
    base = SuiteGate.result(@suite, run(), passing())

    for status <- ["compliant", "violating", "unknown"],
        certification <- ["certified", "not_certified", "no_published_band_table"] do
      score = %{
        "scorer" => "agent_reply_style/hs4_claim_only_built_and_proven",
        "kind" => "judged",
        "status" => status,
        "certification" => %{"status" => certification},
        "gates" => false
      }

      summary = %{
        "quality" => %{"pass_rate" => 1.0},
        "safety" => %{"hard_failures" => 0},
        "judged" => %{"verdict" => "fail", "certification" => %{"status" => certification}}
      }

      judged = Enum.map(passing(), &Map.put(&1, :scores, [score]))

      assert SuiteGate.result(@suite, run(summary), judged) == base
    end

    # And a failing run is failed for its deterministic reasons alone.
    failing = run(%{"quality" => %{"pass_rate" => 0.1}, "safety" => %{"hard_failures" => 0}})
    assert SuiteGate.result(@suite, failing, passing())["reasons"] == ["below_threshold"]
  end
end
