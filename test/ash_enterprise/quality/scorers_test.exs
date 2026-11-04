defmodule AshEnterprise.Quality.ScorersTest do
  @moduledoc """
  The deterministic scorers that came from the assistant's eval dimensions (ADR 0058):
  what each measures from what a run recorded, with no database and no model.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Quality.Assertions
  alias AshEnterprise.Quality.Scorers.ArgMatch

  defp observed(attrs \\ %{}) do
    Map.merge(
      %{
        run: %{step_count: 2, status: :completed, error_code: nil, blocked_on: nil},
        tool_names: MapSet.new(["calendar_events"]),
        invocations: [
          %{target: "calendar_events", args: %{"window" => "tomorrow"}, approval_mode: nil}
        ],
        answer: "Tomorrow: the SYNTHETIC roadmap sync [[calendar:1]].",
        calls: [
          %{name: "calendar_events", arguments: %{}, ok: true, surface?: false, proposal: nil}
        ],
        refs: ["calendar:1"]
      },
      attrs
    )
  end

  defp status(assertion, observed \\ observed()),
    do: Assertions.evaluate(assertion, observed)["status"]

  describe "ArgMatch" do
    test "literals, and each matcher" do
      args = %{"window" => "tomorrow", "text" => "Roadmap sync", "account" => nil}

      assert ArgMatch.holds?(%{"window" => "tomorrow"}, args)
      refute ArgMatch.holds?(%{"window" => "today"}, args)
      assert ArgMatch.holds?(%{"text" => %{"$contains" => "roadmap"}}, args)
      refute ArgMatch.holds?(%{"text" => %{"$contains" => "budget"}}, args)
      assert ArgMatch.holds?(%{"text" => %{"$starts_with" => "Road"}}, args)
      assert ArgMatch.holds?(%{"account" => %{"$in" => ["gmail", nil]}}, args)
      assert ArgMatch.holds?(%{"missing" => %{"$in" => [nil]}}, args)
      refute ArgMatch.holds?(%{"window" => %{"$in" => ["today"]}}, args)
      assert ArgMatch.holds?(%{"window" => %{"$present" => true}}, args)
      refute ArgMatch.holds?(%{"account" => %{"$present" => true}}, args)
    end

    test "$or holds when any alternative does" do
      either = %{"$or" => [%{"attendee" => "quinn"}, %{"text" => %{"$contains" => "quinn"}}]}

      assert ArgMatch.holds?(either, %{"text" => "with Quinn"})
      assert ArgMatch.holds?(either, %{"attendee" => "quinn"})
      refute ArgMatch.holds?(either, %{"text" => "with Rory"})
    end

    test "$window names exactly the days, however the model put it" do
      monday = Date.utc_today() |> Date.beginning_of_week() |> Date.add(7) |> Date.to_iso8601()

      assert ArgMatch.holds?(%{"window" => %{"$window" => [monday, monday]}}, %{
               "window" => monday
             })

      refute ArgMatch.holds?(%{"window" => %{"$window" => [monday, monday]}}, %{"window" => nil})
    end
  end

  describe "tool choice" do
    test "tool_called by a tool's own name, or by any of several" do
      assert status(%{type: :tool_called, target: "calendar_events"}) == "passed"
      assert status(%{type: :tool_called, target: "find_people"}) == "failed"

      assert status(%{type: :tool_called, any_of: ["find_people", "calendar_events"]}) ==
               "passed"

      assert status(%{type: :tool_called, any_of: ["find_people"]}) == "failed"
    end

    test "tool_not_called is hard, and a miss fails" do
      refute status(%{type: :tool_not_called, target: "calendar_events"}) == "passed"

      assert Assertions.evaluate(%{type: :tool_not_called, target: "propose_task"}, observed())[
               "hard"
             ]

      assert status(%{type: :tool_not_called, target: "propose_task"}) == "passed"
    end

    test "a tool_called with neither a target nor alternatives is a problem" do
      assert Assertions.problems(%{type: :tool_called}) == ["tool_called needs a target"]
      assert Assertions.problems(%{type: :tool_called, any_of: ["a"]}) == []
    end
  end

  describe "args_match with matchers" do
    test "a call of the tool must hold them" do
      assert status(%{
               type: :args_match,
               target: "calendar_events",
               args: %{"window" => %{"$in" => ["tomorrow"]}}
             }) == "passed"

      assert status(%{type: :args_match, target: "calendar_events", args: %{"window" => "today"}}) ==
               "failed"
    end
  end

  describe "key facts" do
    test "every fact, ignoring case; a list entry is met by any of its entries" do
      facts = fn facts -> %{type: :facts, expected: %{"facts" => facts}} end

      assert status(facts.(["roadmap sync", "TOMORROW"])) == "passed"
      assert status(facts.([["budget", "roadmap"]])) == "passed"
      assert status(facts.(["roadmap sync", "budget"])) == "failed"
      assert status(facts.(["x"]), observed(%{answer: nil})) == "failed"
    end

    test "facts need facts" do
      assert Assertions.problems(%{type: :facts}) == ["facts needs expected facts"]
    end
  end

  describe "citation coverage" do
    test "counts only refs the tools returned, and reports hits over expected" do
      cites = fn refs -> %{type: :cites, expected: %{"refs" => refs}} end

      assert %{"status" => "passed", "measure" => %{"hit" => 1, "of" => 1}} =
               Assertions.evaluate(cites.(["calendar:1"]), observed())

      # Cited in the answer but never returned by a tool: not a citation.
      assert %{"status" => "failed", "measure" => %{"hit" => 0, "of" => 1}} =
               Assertions.evaluate(cites.(["calendar:1"]), observed(%{refs: []}))

      assert %{"status" => "failed", "measure" => %{"hit" => 1, "of" => 2}} =
               Assertions.evaluate(cites.(["calendar:1", "calendar:2"]), observed())
    end
  end

  describe "surfaces, proposals and accepted calls" do
    test "a surface is composed when some call composed one" do
      assert status(%{type: :surface}) == "failed"

      composed = %{
        name: "compose_surface",
        arguments: %{},
        ok: true,
        surface?: true,
        proposal: nil
      }

      assert status(%{type: :surface}, observed(%{calls: [composed]})) == "passed"
    end

    test "a proposal of the kind, or none for kind false" do
      proposed = %{
        name: "propose_task",
        arguments: %{},
        ok: true,
        surface?: false,
        proposal: "create_task"
      }

      kind = fn kind -> %{type: :proposal, expected: %{"kind" => kind}} end

      assert status(kind.("create_task"), observed(%{calls: [proposed]})) == "passed"
      assert status(kind.("complete_task"), observed(%{calls: [proposed]})) == "failed"
      assert status(kind.(false)) == "passed"
      assert status(kind.(false), observed(%{calls: [proposed]})) == "failed"
    end

    test "calls_accepted reports accepted over made" do
      rejected = %{
        name: "calendar_events",
        arguments: %{},
        ok: false,
        surface?: false,
        proposal: nil
      }

      assert %{"status" => "failed", "measure" => %{"hit" => 1, "of" => 2}} =
               Assertions.evaluate(
                 %{type: :calls_accepted},
                 observed(%{calls: observed().calls ++ [rejected]})
               )
    end
  end

  test "case_status: failed beats errored beats unmeasured" do
    result = &%{"status" => &1}

    assert Assertions.case_status([result.("failed")], false) == :failed
    assert Assertions.case_status([result.("passed")], false) == :errored
    assert Assertions.case_status([result.("unmeasured")], true) == :unmeasured
    assert Assertions.case_status([result.("passed"), result.("unmeasured")], true) == :passed
  end
end
