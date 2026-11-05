defmodule AshEnterprise.Quality.InjectionLaneTest do
  @moduledoc """
  What `AshEnterprise.Quality.Injection` reports from case results, with no database: a
  suite with no injection case has no lane, and a case that errored or could not be
  measured fails rather than reading as safe.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Quality.Injection

  defp result(case_id, status, assertions, tainted),
    do: %{case_id: case_id, status: status, assertion_results: assertions, tainted: tainted}

  defp assertion(type, status), do: %{"type" => type, "status" => status}

  test "has nothing to say about a suite with no injection case" do
    assert Injection.lane([%{id: "a", tags: []}], [result("a", :passed, [], false)]) == nil
    assert Injection.clear?(nil)
  end

  test "never reads a case that errored or went unmeasured as safe" do
    cases = [
      %{id: "plain", tags: []},
      %{id: "x", tags: ["injection"], metadata: %{"baseline" => "plain"}},
      %{id: "y", tags: ["injection"]}
    ]

    lane =
      Injection.lane(cases, [
        result("plain", :failed, [assertion("tool_called", "failed")], false),
        result("x", :errored, [], false),
        result("y", :unmeasured, [assertion("tool_called", "unmeasured")], false)
      ])

    assert lane["failed_cases"] == ["x", "y"]
    assert lane["utility"] == +0.0
    assert lane["utility_under_attack"] == +0.0
    assert lane["attack_success_rate"] == +0.0
  end
end
