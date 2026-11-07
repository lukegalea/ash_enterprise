defmodule AshEnterprise.Quality.ComparisonTest do
  @moduledoc """
  `AshEnterprise.Quality.Comparison.build/4`, the layout of a candidate comparison, over
  plain rows: every quality outcome is its own, safety is a lane of its own that quality
  never averages away, and an errored, unmeasured, skipped, missing or unknown result is
  never read as a pass, a zero or safe, nor lets a candidate be recommended.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Quality.Comparison

  @read "Clinic.Letter.read"
  @refer "Clinic.Board.refer"

  defp suite(cases),
    do: %{id: "suite", key: "clinic.triage", version: 1, content_hash: "h", cases: cases}

  defp plain(id),
    do: %{
      id: id,
      input: "SYNTHETIC: case #{id}",
      assertions: [%{type: :tool_called, target: @read}]
    }

  defp injection(id),
    do: %{
      id: id,
      input: "SYNTHETIC: injected #{id}",
      tags: ["injection"],
      assertions: [
        %{type: :tool_called, target: @read},
        %{type: :prohibited_effect, target: @refer}
      ]
    }

  defp run(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        mode: :offline,
        status: :finished,
        imported: false,
        agent_key: "clinic.triage",
        agent_version_id: nil,
        candidate_digest: "digest-#{id}",
        created_on: ~U[2026-11-07 10:00:00Z],
        finished_at: ~U[2026-11-07 10:05:00Z]
      },
      attrs
    )
  end

  # A result of `status`; `:attacked` fails the prohibited effect, `:hard` a hard assertion.
  defp result(run_id, case_id, status, opts \\ []) do
    assertions =
      case Keyword.get(opts, :as, status) do
        :attacked ->
          [
            %{"type" => "tool_called", "hard" => false, "status" => "passed"},
            %{"type" => "prohibited_effect", "hard" => true, "status" => "failed"}
          ]

        :hard ->
          [%{"type" => "schema_valid", "hard" => true, "status" => "failed"}]

        :passed ->
          [%{"type" => "tool_called", "hard" => false, "status" => "passed"}]

        _other ->
          [%{"type" => "tool_called", "hard" => false, "status" => "failed"}]
      end

    %{
      id: "#{run_id}-#{case_id}",
      suite_run_id: run_id,
      case_id: case_id,
      epoch: Keyword.get(opts, :epoch, 1),
      status: status,
      assertion_results: assertions,
      prohibited_effect_hit: Keyword.get(opts, :as) == :attacked,
      run_id: "agent-run-#{run_id}-#{case_id}"
    }
  end

  defp cell(comparison, case_id, run_id) do
    row = Enum.find(comparison.quality, &(&1.case_id == case_id))
    row.cells[run_id]
  end

  defp candidate(comparison, id), do: Enum.find(comparison.candidates, &(&1.id == id))

  defp safety(comparison, key, run_id) do
    Enum.find(comparison.safety, &(&1.key == key)).cells[run_id]
  end

  defp injection_cell(comparison, case_id, run_id) do
    Enum.find(comparison.safety, &(&1[:case_id] == case_id)).cells[run_id]
  end

  describe "the quality lane" do
    setup do
      cases = Enum.map(~w(kept better worse both skip unmeasured gone), &plain/1)

      results =
        [
          result("a", "kept", :passed),
          result("a", "better", :failed),
          result("a", "worse", :passed),
          result("a", "both", :failed),
          result("a", "skip", :passed),
          result("a", "unmeasured", :passed),
          result("a", "gone", :passed),
          result("b", "kept", :passed),
          result("b", "better", :passed),
          result("b", "worse", :errored),
          result("b", "both", :failed),
          result("b", "skip", :skipped),
          result("b", "unmeasured", :unmeasured)
        ]

      %{comparison: Comparison.build(suite(cases), [run("a"), run("b")], results)}
    end

    test "improved, degraded, failed, skipped, not measured and missing are distinct outcomes",
         %{comparison: comparison} do
      assert comparison.baseline_id == "a"

      outcomes =
        for c <- ~w(kept better worse both skip unmeasured gone),
            do: cell(comparison, c, "b").outcome

      assert outcomes == [:passed, :improved, :degraded, :failed, :skipped, :unmeasured, :missing]
      assert Enum.uniq(outcomes) == outcomes

      # The baseline's own cells are what it recorded, never compared with itself.
      assert cell(comparison, "better", "a").outcome == :failed
      assert cell(comparison, "worse", "a").outcome == :passed
      # A degraded cell keeps what was recorded.
      assert cell(comparison, "worse", "b").status == :errored
    end

    test "a missing case is counted and has no result to link to", %{comparison: comparison} do
      gone = cell(comparison, "gone", "b")
      assert gone == %{status: :missing, outcome: :missing, result_id: nil, run_id: nil}
      assert candidate(comparison, "b").missing == 1
      assert candidate(comparison, "a").missing == 0
      assert comparison.missing == 1
    end

    test "the aggregate counts every outcome, and a missing or unmeasured case is never a pass",
         %{comparison: comparison} do
      quality = candidate(comparison, "b").quality

      assert Map.take(quality, [
               :passed,
               :improved,
               :degraded,
               :failed,
               :errored,
               :skipped,
               :unmeasured,
               :missing
             ]) ==
               %{
                 passed: 2,
                 improved: 1,
                 degraded: 1,
                 failed: 1,
                 errored: 0,
                 skipped: 1,
                 unmeasured: 1,
                 missing: 1
               }

      # Passed over every ordinary case: the skipped, unmeasured and missing ones count against it.
      assert quality.rate == 2 / 7
      assert candidate(comparison, "a").quality.rate == 5 / 7
    end

    test "a candidate is blocked while a case has no result", %{comparison: comparison} do
      assert :cases_missing in candidate(comparison, "b").blocked
    end
  end

  describe "not measured is never zero" do
    test "a candidate with no ordinary result has no rate, not 0" do
      cases = [plain("one"), plain("two")]
      results = [result("b", "one", :unmeasured), result("b", "two", :skipped)]
      comparison = Comparison.build(suite(cases), [run("b")], results)

      quality = candidate(comparison, "b").quality
      assert quality.rate == nil
      assert quality.passed == 0
      assert :quality_not_measured in Comparison.blocked(candidate(comparison, "b"))
    end

    test "a running candidate's safety counts are not measured, not 0, and its safety is not measured" do
      cases = [plain("one"), injection("inj")]
      runs = [run("a"), run("b", %{status: :running, finished_at: nil})]
      results = [result("a", "one", :passed), result("a", "inj", :passed)]
      comparison = Comparison.build(suite(cases), runs, results)

      assert safety(comparison, :hard_failures, "b") == %{count: nil}
      assert safety(comparison, :prohibited_effects, "b") == %{count: nil}
      assert safety(comparison, :hard_failures, "a") == %{count: 0}
      assert injection_cell(comparison, "inj", "b").outcome == :missing

      running = candidate(comparison, "b")
      assert running.safety == :not_measured
      assert running.safety_reasons == [:not_finished]
      assert :not_finished in running.blocked
      assert cell(comparison, "one", "b").outcome == :missing
    end

    test "a finished run with no results at all is not measured, not 0" do
      comparison =
        Comparison.build(suite([plain("one")]), [run("a"), run("b")], [
          result("a", "one", :passed)
        ])

      assert safety(comparison, :hard_failures, "b") == %{count: nil}
      assert candidate(comparison, "b").safety == :not_measured
      assert candidate(comparison, "b").quality.rate == nil
    end
  end

  describe "the safety lane" do
    setup do
      %{cases: [plain("one"), plain("two"), injection("inj")]}
    end

    test "injection cases are reported in the safety lane, never in the quality aggregate", %{
      cases: cases
    } do
      results = [
        result("a", "one", :passed),
        result("a", "two", :failed),
        result("a", "inj", :passed),
        result("b", "one", :passed),
        result("b", "two", :passed),
        result("b", "inj", :failed, as: :attacked)
      ]

      comparison = Comparison.build(suite(cases), [run("a"), run("b")], results)

      assert Enum.map(comparison.quality, & &1.case_id) == ["one", "two"]
      assert comparison.suite.ordinary == 2
      assert comparison.suite.injection == 1

      # Better quality, and the attack worked: the quality lane shows the one, safety the other.
      better = candidate(comparison, "b")
      assert better.quality.rate == 1.0
      assert better.quality.cases == 2
      assert injection_cell(comparison, "inj", "b").outcome == :attacked
      assert injection_cell(comparison, "inj", "a").outcome == :held
      assert safety(comparison, :prohibited_effects, "b") == %{count: 1}
      assert safety(comparison, :hard_failures, "b") == %{count: 1}

      assert better.safety == :failed
      assert :injection_failed in better.safety_reasons
      assert :prohibited_effect in better.safety_reasons

      # It is not the best overall, however good its quality: the weaker, safe one is.
      assert :safety_failed in better.blocked
      assert comparison.recommended == "a"
      assert comparison.reason == :recommended
    end

    for status <- [:errored, :unmeasured, :skipped] do
      test "an #{status} injection case blocks the recommendation", %{cases: cases} do
        results = [
          result("a", "one", :passed),
          result("a", "two", :failed),
          result("a", "inj", unquote(status)),
          result("b", "one", :passed),
          result("b", "two", :passed),
          result("b", "inj", unquote(status))
        ]

        comparison = Comparison.build(suite(cases), [run("a"), run("b")], results)

        for id <- ["a", "b"] do
          assert candidate(comparison, id).safety == :not_measured
          assert :injection_not_measured in candidate(comparison, id).safety_reasons
          assert :safety_not_measured in candidate(comparison, id).blocked
        end

        assert injection_cell(comparison, "inj", "b").outcome == unquote(status)
        assert comparison.recommended == nil
        assert comparison.reason == :none_qualifies
      end
    end

    test "a missing injection result blocks the recommendation", %{cases: cases} do
      results = [
        result("a", "one", :passed),
        result("a", "two", :passed),
        result("a", "inj", :passed),
        result("b", "one", :passed),
        result("b", "two", :passed)
      ]

      comparison = Comparison.build(suite(cases), [run("a"), run("b")], results)
      blocked = candidate(comparison, "b")

      assert injection_cell(comparison, "inj", "b").outcome == :missing
      assert blocked.safety == :not_measured
      assert :cases_missing in blocked.safety_reasons
      assert :injection_not_measured in blocked.safety_reasons
      assert :safety_not_measured in blocked.blocked
      # The candidate measured on every case is the one recommended.
      assert comparison.recommended == "a"
    end

    test "an unknown injection status is not read as held", %{cases: cases} do
      results = [
        result("a", "one", :passed),
        result("a", "two", :passed),
        result("a", "inj", :pending),
        result("b", "one", :passed),
        result("b", "two", :passed),
        result("b", "inj", :passed)
      ]

      comparison = Comparison.build(suite(cases), [run("a"), run("b")], results)

      assert injection_cell(comparison, "inj", "a").outcome == :pending
      assert candidate(comparison, "a").safety == :not_measured
      assert candidate(comparison, "b").safety == :clear
      assert comparison.recommended == "b"
    end

    test "a hard assertion that errored, or that nothing measured, is not safe" do
      hard = %{
        id: "hard",
        input: "SYNTHETIC: answer in shape",
        assertions: [%{type: :schema_valid}]
      }

      for status <- [:errored, :unmeasured, :skipped, :pending] do
        results = [result("a", "hard", :passed), result("b", "hard", status)]
        comparison = Comparison.build(suite([hard]), [run("a"), run("b")], results)

        assert candidate(comparison, "b").safety == :not_measured,
               "#{status} read as safe"

        assert :hard_not_measured in candidate(comparison, "b").safety_reasons
        assert candidate(comparison, "a").safety == :clear
      end
    end

    test "a failed hard assertion fails safety whatever the quality" do
      hard = %{
        id: "hard",
        input: "SYNTHETIC: answer in shape",
        assertions: [%{type: :schema_valid}]
      }

      results = [result("a", "hard", :passed), result("b", "hard", :failed, as: :hard)]
      comparison = Comparison.build(suite([hard]), [run("a"), run("b")], results)

      assert candidate(comparison, "b").safety == :failed
      assert candidate(comparison, "b").safety_reasons == [:hard_failure]
      assert safety(comparison, :hard_failures, "b") == %{count: 1}
    end

    test "every epoch counts for safety: a later epoch's attack or hard failure is never dropped",
         %{cases: cases} do
      results = [
        result("a", "one", :passed),
        result("a", "two", :passed),
        result("a", "inj", :passed),
        result("b", "one", :passed),
        result("b", "one", :failed, as: :hard, epoch: 2),
        result("b", "two", :passed),
        result("b", "inj", :passed, epoch: 1),
        result("b", "inj", :failed, as: :attacked, epoch: 2)
      ]

      comparison = Comparison.build(suite(cases), [run("a"), run("b")], results)
      b = candidate(comparison, "b")

      assert b.safety == :failed
      assert :hard_failure in b.safety_reasons
      assert :prohibited_effect in b.safety_reasons
      assert :injection_failed in b.safety_reasons
      assert injection_cell(comparison, "inj", "b").outcome == :attacked
      assert safety(comparison, :prohibited_effects, "b") == %{count: 1}
      assert safety(comparison, :hard_failures, "b") == %{count: 2}
      assert comparison.recommended == "a"
    end

    test "a later epoch that was not measured leaves safety not measured", %{cases: cases} do
      results = [
        result("a", "one", :passed),
        result("a", "two", :passed),
        result("a", "inj", :passed, epoch: 1),
        result("a", "inj", :errored, epoch: 2)
      ]

      comparison = Comparison.build(suite(cases), [run("a")], results)
      a = candidate(comparison, "a")

      assert a.safety == :not_measured
      assert :injection_not_measured in a.safety_reasons
      assert injection_cell(comparison, "inj", "a").outcome == :errored
    end

    test "the verdict row carries each candidate's safety", %{cases: cases} do
      results = for id <- ["a"], c <- ["one", "two", "inj"], do: result(id, c, :passed)
      comparison = Comparison.build(suite(cases), [run("a")], results)

      assert safety(comparison, :verdict, "a") == %{safety: :clear, safety_reasons: []}
    end
  end

  describe "recommended" do
    setup do
      %{cases: [plain("one"), plain("two"), injection("inj")]}
    end

    defp all(run_id, statuses) do
      for {case_id, status} <- statuses, do: result(run_id, to_string(case_id), status)
    end

    test "the best quality among the candidates whose safety is clear", %{cases: cases} do
      results =
        all("a", one: :passed, two: :failed, inj: :passed) ++
          all("b", one: :passed, two: :passed, inj: :passed)

      comparison = Comparison.build(suite(cases), [run("a"), run("b")], results)

      assert {comparison.recommended, comparison.reason} == {"b", :recommended}
      assert candidate(comparison, "b").blocked == []
    end

    test "a shared best rate recommends no one", %{cases: cases} do
      results =
        all("a", one: :passed, two: :passed, inj: :passed) ++
          all("b", one: :passed, two: :passed, inj: :passed)

      comparison = Comparison.build(suite(cases), [run("a"), run("b")], results)
      assert {comparison.recommended, comparison.reason} == {nil, :tied}
    end

    test "one candidate is nothing to compare", %{cases: cases} do
      comparison =
        Comparison.build(
          suite(cases),
          [run("a")],
          all("a", one: :passed, two: :passed, inj: :passed)
        )

      assert {comparison.recommended, comparison.reason} == {nil, :nothing_to_compare}
    end

    test "imported results name no candidate, so they are never recommended", %{cases: cases} do
      results =
        all("a", one: :passed, two: :failed, inj: :passed) ++
          all("b", one: :passed, two: :passed, inj: :passed)

      comparison =
        Comparison.build(suite(cases), [run("a"), run("b", %{imported: true})], results)

      assert :imported in candidate(comparison, "b").blocked
      assert comparison.recommended == "a"
    end

    test "the baseline is the oldest finished run here, or the one named", %{cases: cases} do
      runs = [run("i", %{imported: true}), run("r", %{status: :running}), run("a"), run("b")]

      results =
        all("a", one: :failed, two: :passed, inj: :passed) ++
          all("b", one: :passed, two: :passed, inj: :passed)

      assert Comparison.build(suite(cases), runs, results).baseline_id == "a"

      named = Comparison.build(suite(cases), runs, results, baseline: "b")
      assert named.baseline_id == "b"
      assert cell(named, "one", "a").outcome == :degraded

      # A name that is not one of the runs falls back.
      assert Comparison.build(suite(cases), runs, results, baseline: "nope").baseline_id == "a"
    end

    test "no decided baseline result: a pass is a pass, not an improvement", %{cases: cases} do
      results =
        all("a", one: :unmeasured, two: :passed, inj: :passed) ++
          all("b", one: :passed, two: :passed, inj: :passed)

      comparison = Comparison.build(suite(cases), [run("a"), run("b")], results)

      assert cell(comparison, "one", "b").outcome == :passed
    end

    test "the first epoch of a case is the one compared", %{cases: cases} do
      results = [
        result("a", "one", :failed, epoch: 2),
        result("a", "one", :passed, epoch: 1),
        result("a", "two", :passed),
        result("a", "inj", :passed)
      ]

      comparison = Comparison.build(suite(cases), [run("a")], results)
      assert cell(comparison, "one", "a").status == :passed
    end
  end
end
