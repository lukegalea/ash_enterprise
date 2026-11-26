defmodule AshBrowserTests.SurfacesTest do
  # Generated tests: one per surface, one per action, one ledger, from the fixture host.
  use AshBrowserTests.Surfaces, host: AshBrowserTests.Fixture.Surfaces, async: true

  alias AshBrowserTests.Fixture.BadSurfaces
  alias AshBrowserTests.Fixture.FailingAuditSurfaces
  alias AshBrowserTests.Fixture.ServerChainSurfaces
  alias AshBrowserTests.Surfaces

  @tag allow_browser_failures: true
  test "a console error on a surface fails its generated test", context do
    assert_raise ExUnit.AssertionError, ~r/fixture console error/, fn ->
      Surfaces.run(BadSurfaces, Map.put(context, :generated, {:surface, "console"}))
    end
  end

  test "a host's row-action chain replaces the default, and the audit check still gets the handle_event span's correlation id",
       context do
    [%AshBrowserTests.Action{chain: [first, _ash_action]}] =
      ServerChainSurfaces
      |> Surfaces.declared()
      |> Enum.find(&(&1.id == "widgets"))
      |> Map.fetch!(:actions)
      |> Enum.filter(&(&1.id == "row:activate"))

    assert first == AshBrowserTests.Trace.handle_event()

    Surfaces.run(
      ServerChainSurfaces,
      Map.put(context, :generated, {:action, "widgets", "row:activate"})
    )
  end

  test "a row action whose audit check fails fails its generated test", context do
    assert_raise RuntimeError, ~r/fixture audit row missing/, fn ->
      Surfaces.run(
        FailingAuditSurfaces,
        Map.put(context, :generated, {:action, "widgets", "row:activate"})
      )
    end
  end
end
