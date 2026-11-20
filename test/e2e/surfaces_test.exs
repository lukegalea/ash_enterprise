defmodule AshEnterpriseWeb.E2E.SurfacesTest do
  @moduledoc """
  A generated test per adopted surface: signed in as the surface's actor, the
  page connects, the surface mounts, the trace runs unbroken from the browser's
  connect through the LiveView mount to the SQL, and the browser reports no
  console error, page error or 5xx.

  Which surfaces, and why not all of them, is in
  `AshEnterpriseWeb.E2E.Surfaces`.
  """

  use AshBrowserTests.Surfaces, host: AshEnterpriseWeb.E2E.Surfaces, async: true
end
