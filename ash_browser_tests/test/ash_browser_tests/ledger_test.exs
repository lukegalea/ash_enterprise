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

  describe "waivers taken together" do
    test "two waivers of one thing fail, the second named" do
      first = {:undocumented, :surface, "b", "internal only"}
      second = {:undocumented, :surface, "b", "kept for the operators"}

      assert [{:duplicate_waiver, ^second}] = Ledger.waiver_problems([first, second])

      action = {:undocumented, :action, {"a", "go"}, "an admin repair"}
      again = {:undocumented, :action, {"a", "go"}, "a repair for administrators"}
      assert [{:duplicate_waiver, ^again}] = Ledger.waiver_problems([action, again])
    end

    test "one reason given by several waivers fails, even with each one's id spliced in" do
      stock = [
        {:undocumented, :surface, "a", "Surface a: not documented yet."},
        {:undocumented, :surface, "b", "surface B -- not documented yet"},
        {:undocumented, :surface, "c", "Surface c, not documented yet"}
      ]

      assert [{:repeated_reason, ^stock} = problem] = Ledger.waiver_problems(stock)
      assert Ledger.format_problem(problem) =~ "3 waivers give one reason between them"
    end

    test "a reason that is only the waiver's own id is a stock reason" do
      waivers = [{:undocumented, :surface, "a", "a"}, {:undocumented, :surface, "b", "B."}]
      assert [{:repeated_reason, ^waivers}] = Ledger.waiver_problems(waivers)
    end

    test "waivers with reasons of their own pass, and a blank reason is left to the accounts" do
      waivers = [
        {:undocumented, :surface, "a", "internal only"},
        {:undocumented, :surface, "b", "replaced next quarter"},
        {:undocumented, :action, {"a", "go"}, " "},
        {:undocumented, :action, {"a", "stop"}, ""}
      ]

      assert Ledger.waiver_problems(waivers) == []
    end
  end

  describe "documentation coverage" do
    test "counts what journeys walk, and never a waiver" do
      surfaces = surfaces() ++ [%Surface{id: "c", path: "/c"}]
      walked = [{:journey, "j", {:surface, "a"}}, {:journey, "j", {:action, "a", "go"}}]

      expected = %{surfaces: %{documented: 1, of: 3}, actions: %{documented: 1, of: 2}}
      assert Ledger.documentation_coverage(surfaces, walked) == expected

      # A walk of something not in the set counts for nothing.
      assert Ledger.documentation_coverage(surfaces, [{:journey, "j", {:surface, "z"}} | walked]) ==
               expected

      assert Ledger.documentation_coverage(surfaces, []) ==
               %{surfaces: %{documented: 0, of: 3}, actions: %{documented: 0, of: 2}}
    end
  end

  describe "documented by an approved journey" do
    alias AshBrowserTests.Fixture.ApprovedRuns
    alias AshBrowserTests.Fixture.Journeys, as: FixtureJourneys
    alias AshBrowserTests.Journeys
    alias AshJourneys.Lock

    @opts [manifest_opts: ApprovedRuns.manifest_opts()]

    # A surfaces host: widgets with both row actions the fixture's journeys
    # perform, and a page no journey opens.
    defp host(waivers) do
      host = Module.concat(__MODULE__, "Host#{System.unique_integer([:positive])}")

      surfaces = [
        %Surface{
          id: "widgets",
          path: "/journey/widgets",
          actions: [%Action{id: "row:widgets.activate"}, %Action{id: "row:widgets.remove"}]
        },
        %Surface{id: "plain", path: "/plain"}
      ]

      Module.create(
        host,
        quote do
          def surfaces, do: unquote(Macro.escape(surfaces))
          def waivers, do: unquote(Macro.escape(waivers))
        end,
        Macro.Env.location(__ENV__)
      )

      host
    end

    defp plain_waiver, do: {:undocumented, :surface, "plain", "a test page with nothing to do"}

    defp remove_waiver,
      do: {:undocumented, :action, {"widgets", "row:widgets.remove"}, "removal is irreversible"}

    test "a journey with no approved run walks nothing" do
      root = ApprovedRuns.root()

      assert {:ok, %{documented: [], unproven: unproven}} =
               Journeys.proven([FixtureJourneys], root, @opts)

      assert unproven == [
               {"activate_a_widget", "en", :unapproved, []},
               {"remove_a_widget", "en", :unapproved, []}
             ]

      # documented/1 still reports every declaration, approved or not.
      assert Journeys.documented([FixtureJourneys]) != []
    end

    test "an approved, current journey walks its surfaces and row actions; the others do not" do
      root = ApprovedRuns.root()
      :ok = ApprovedRuns.approve!(root, [FixtureJourneys], "r1", ["activate_a_widget"])

      assert {:ok, %{documented: documented, unproven: unproven}} =
               Journeys.proven([FixtureJourneys], root, @opts)

      assert Enum.sort(documented) == [
               {:journey, "activate_a_widget", {:surface, "widgets"}},
               {:journey, "activate_a_widget", {:action, "widgets", "row:widgets.activate"}}
             ]

      assert unproven == [{"remove_a_widget", "en", :unapproved, []}]
    end

    test "a stale run walks nothing: the lock's pinned build moved after approval" do
      root = ApprovedRuns.root()
      :ok = ApprovedRuns.approve!(root, [FixtureJourneys], "r1", ["activate_a_widget"])
      {:ok, lock} = Lock.read(root)
      Lock.write!(%{lock | browser: %{name: "chromium", version: "999.0.0.0"}}, root)

      assert {:ok, %{documented: [], unproven: unproven}} =
               Journeys.proven([FixtureJourneys], root, @opts)

      assert [{"activate_a_widget", "en", :stale, [reason]}, {"remove_a_widget", "en", _, _}] =
               unproven

      assert reason =~ "the lock pins chromium 999.0.0.0"
    end

    test "an altered approved run walks nothing" do
      root = ApprovedRuns.root()
      :ok = ApprovedRuns.approve!(root, [FixtureJourneys], "r1", ["activate_a_widget"])
      dir = Lock.approved_dir(root, "en", "activate_a_widget")
      File.write!(Path.join(dir, "activate.activated.png"), "not the approved bytes")

      assert {:ok, %{documented: [], unproven: [{"activate_a_widget", "en", :altered, _} | _]}} =
               Journeys.proven([FixtureJourneys], root, @opts)
    end

    test "a lock that does not read, or a module that declares no journeys, is an error" do
      root = ApprovedRuns.root()
      File.mkdir_p!(Path.dirname(Lock.path(root)))
      File.write!(Lock.path(root), "{")
      assert {:error, [_ | _]} = Journeys.proven([FixtureJourneys], root, @opts)

      assert {:error, [problem]} = Journeys.proven([Ledger], ApprovedRuns.root(), @opts)
      assert problem =~ "does not use AshJourneys.Journeys"
    end

    test "assert_documented!/3 passes when the rest is waived by hand" do
      root = ApprovedRuns.root()
      :ok = ApprovedRuns.approve!(root, [FixtureJourneys], "r1", ["activate_a_widget"])
      host = host([plain_waiver(), remove_waiver()])

      assert :ok = Journeys.assert_documented!(host, [FixtureJourneys], [root: root] ++ @opts)
    end

    test "assert_documented!/3 fails on what an unapproved journey would walk, and says why" do
      root = ApprovedRuns.root()
      :ok = ApprovedRuns.approve!(root, [FixtureJourneys], "r1", ["activate_a_widget"])
      host = host([plain_waiver()])

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Journeys.assert_documented!(host, [FixtureJourneys], [root: root] ++ @opts)
        end

      assert error.message =~
               ~s|action "row:widgets.remove" on surface "widgets" is in no journey|

      assert error.message =~ "journey remove_a_widget walks nothing yet: en is unapproved"
    end

    test "a waiver of what an unapproved journey walks is not stale until the journey is approved" do
      root = ApprovedRuns.root()
      :ok = ApprovedRuns.approve!(root, [FixtureJourneys], "r1", ["activate_a_widget"])
      host = host([plain_waiver(), remove_waiver()])
      assert :ok = Journeys.assert_documented!(host, [FixtureJourneys], [root: root] ++ @opts)

      :ok = ApprovedRuns.approve!(root, [FixtureJourneys], "r2", ["remove_a_widget"])

      assert_raise ExUnit.AssertionError,
                   ~r/excuses what journey remove_a_widget walks; remove it/,
                   fn ->
                     Journeys.assert_documented!(host, [FixtureJourneys], [root: root] ++ @opts)
                   end
    end

    test "assert_documented!/3 refuses a waiver without a reason, a stale one, a duplicate and a stock reason" do
      root = ApprovedRuns.root()
      :ok = ApprovedRuns.approve!(root, [FixtureJourneys], "r1", ["activate_a_widget"])

      refused = [
        {[{:undocumented, :surface, "plain", " "}, remove_waiver()], ~r/has no reason/},
        {[plain_waiver(), remove_waiver(), {:undocumented, :surface, "gone", "was removed"}],
         ~r/names nothing declared/},
        {[plain_waiver(), remove_waiver(), {:undocumented, :surface, "plain", "a second word"}],
         ~r/waives what an earlier waiver already does/},
        {[
           {:undocumented, :surface, "plain", "plain: no journey yet"},
           {:undocumented, :action, {"widgets", "row:widgets.remove"},
            "Widgets remove; no journey yet"}
         ], ~r/2 waivers give one reason between them/}
      ]

      for {waivers, message} <- refused do
        assert_raise ExUnit.AssertionError, message, fn ->
          Journeys.assert_documented!(host(waivers), [FixtureJourneys], [root: root] ++ @opts)
        end
      end
    end

    test "assert_documented!/3 fails when the journeys or the lock do not read" do
      assert_raise ExUnit.AssertionError, ~r/do not read/, fn ->
        Journeys.assert_documented!(host([]), [Ledger], root: ApprovedRuns.root())
      end
    end
  end
end
