defmodule AshBrowserTests.SurfacesTest do
  # Generated tests: one per surface, one per action, one ledger, from the fixture host.
  use AshBrowserTests.Surfaces, host: AshBrowserTests.Fixture.Surfaces, async: true

  alias AshBrowserTests.Fixture.BadSurfaces
  alias AshBrowserTests.Surfaces

  @tag allow_browser_failures: true
  test "a console error on a surface fails its generated test", context do
    assert_raise ExUnit.AssertionError, ~r/fixture console error/, fn ->
      Surfaces.run(BadSurfaces, Map.put(context, :generated, {:surface, "console"}))
    end
  end
end
