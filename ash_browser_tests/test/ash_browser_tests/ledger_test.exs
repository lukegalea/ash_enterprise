defmodule AshBrowserTests.LedgerTest do
  use ExUnit.Case, async: true

  alias AshBrowserTests.Action
  alias AshBrowserTests.Fixture.Surfaces
  alias AshBrowserTests.Fixture.UnwaivedSurfaces
  alias AshBrowserTests.Ledger
  alias AshBrowserTests.Surface
  alias AshBrowserTests.Surfaces, as: Generator

  defp surfaces do
    [
      %Surface{id: "a", path: "/a", actions: [%Action{id: "go", run: & &1}]},
      %Surface{id: "b", path: nil, actions: [%Action{id: "nope"}]}
    ]
  end

  defp exercised, do: [{:surface, "a"}, {:action, "a", "go"}]

  test "complete when every obligation is exercised or waived" do
    waivers = [{:surface, "b", "no ui"}]
    assert Ledger.problems(surfaces(), waivers, exercised()) == []
    assert :ok = Ledger.assert_complete!(surfaces(), waivers, exercised())
  end

  test "a new surface with no test and no waiver fails" do
    assert [{:unexercised_surface, "b"}, _action] = Ledger.problems(surfaces(), [], exercised())

    assert_raise ExUnit.AssertionError, ~r/surface "b" has no test and no waiver/, fn ->
      Ledger.assert_complete!(surfaces(), [], exercised())
    end
  end

  test "an action without a run and no waiver fails, even when the surface is exercised" do
    surfaces = [%Surface{id: "a", path: "/a", actions: [%Action{id: "nope"}]}]

    assert [{:unexercised_action, {"a", "nope"}}] =
             Ledger.problems(surfaces, [], [{:surface, "a"}])
  end

  test "waiving a surface covers its actions" do
    assert [] = Ledger.problems(surfaces(), [{:surface, "b", "no ui"}], exercised())
  end

  test "an action waiver covers that action only" do
    waivers = [{:action, "b", "nope", "reason"}]
    assert [{:unexercised_surface, "b"}] = Ledger.problems(surfaces(), waivers, exercised())
  end

  test "a waiver with no reason, or a blank one, fails" do
    assert Enum.any?(
             Ledger.problems(surfaces(), [{:surface, "b", "   "}], exercised()),
             &match?({:waiver_without_reason, _}, &1)
           )

    assert_raise ExUnit.AssertionError, ~r/has no reason/, fn ->
      Ledger.assert_complete!(surfaces(), [{:surface, "b", ""}], exercised())
    end
  end

  test "a waiver for something no longer declared is stale" do
    assert [{:stale_waiver, _}, _, _] =
             Ledger.problems(surfaces(), [{:surface, "gone", "was removed"}], exercised())
             |> Enum.sort_by(&(elem(&1, 0) != :stale_waiver))
  end

  describe "against a host" do
    test "generated/1 lists surfaces and runnable, unwaived actions" do
      names = Surfaces |> Generator.generated() |> Enum.map(&elem(&1, 0))

      assert "surface widgets" in names
      assert "surface whoami" in names
      assert "action widgets / create" in names
      assert "action widgets / row:activate" in names
      refute "surface headless" in names
      refute "action widgets / waived-action" in names
    end

    test "a host with an undriven surface and action fails its ledger" do
      assert_raise ExUnit.AssertionError, ~r/no-path-no-waiver/, fn ->
        Generator.assert_ledger!(UnwaivedSurfaces)
      end

      assert_raise ExUnit.AssertionError, ~r/unrunnable/, fn ->
        Generator.assert_ledger!(UnwaivedSurfaces)
      end
    end

    test "a duplicate surface id is a programming error" do
      host = Module.concat(__MODULE__, "Dupes#{System.unique_integer([:positive])}")

      defmodule host do
        def surfaces, do: [%Surface{id: "x", path: "/a"}, %Surface{id: "x", path: "/b"}]
        def waivers, do: []
      end

      assert_raise ArgumentError, ~r/duplicate surface/, fn -> Generator.generated(host) end
    end
  end

  describe "the documentation account" do
    defp walked do
      [
        {:journey, "a_journey", {:surface, "a"}},
        {:journey, "a_journey", {:action, "a", "go"}}
      ]
    end

    test "complete when every surface and action is walked or waived as undocumented" do
      waivers = [{:surface, "b", "no ui"}, {:undocumented, :surface, "b", "internal only"}]
      assert Ledger.documentation_problems(surfaces(), waivers, walked()) == []
      assert :ok = Ledger.assert_documented!(surfaces(), waivers, walked())
    end

    test "reads only :undocumented waivers, and the exercise account ignores them" do
      waivers = [{:surface, "b", "no ui"}]

      assert [{:undocumented_surface, "b"}, {:undocumented_action, {"b", "nope"}}] =
               Ledger.documentation_problems(surfaces(), waivers, walked())

      waivers = [{:undocumented, :surface, "b", "internal only"}]

      assert [{:unexercised_surface, "b"}, _action] =
               Ledger.problems(surfaces(), waivers, exercised())
    end

    test "an action no journey performs needs its own waiver" do
      only_the_page = [{:journey, "a_journey", {:surface, "a"}}]
      waivers = [{:undocumented, :surface, "b", "internal only"}]

      assert_raise ExUnit.AssertionError, ~r/action "go" on surface "a" is in no journey/, fn ->
        Ledger.assert_documented!(surfaces(), waivers, only_the_page)
      end

      waivers = [{:undocumented, :action, {"a", "go"}, "an admin repair"} | waivers]
      assert Ledger.documentation_problems(surfaces(), waivers, only_the_page) == []
    end

    test "a waiver that is unexplained, names nothing, or excuses a walked surface fails" do
      waivers = [
        {:undocumented, :surface, "b", " "},
        {:undocumented, :surface, "gone", "removed last year"},
        {:undocumented, :action, {"a", "go"}, "an admin repair"}
      ]

      assert [
               {:waiver_without_reason, {:undocumented, :surface, "b", " "}},
               {:stale_waiver, {:undocumented, :surface, "gone", _}},
               {:documented_waiver, {{:undocumented, :action, {"a", "go"}, _}, "a_journey"}}
             ] = Ledger.documentation_problems(surfaces(), waivers, walked())
    end

    test "a journey names its surfaces and row actions as the generator does" do
      documented = AshBrowserTests.Journeys.documented([AshBrowserTests.Fixture.Journeys])

      assert {:journey, "activate_a_widget", {:surface, "widgets"}} in documented

      assert {:journey, "activate_a_widget", {:action, "widgets", "row:widgets.activate"}} in documented

      assert {:journey, "remove_a_widget", {:action, "widgets", "row:widgets.remove"}} in documented

      assert length(documented) == length(Enum.uniq(documented))
    end
  end
end
