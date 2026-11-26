defmodule AshEnterpriseWeb.E2E.MissingAuditSurfaces do
  @moduledoc """
  `AshEnterpriseWeb.E2E.Surfaces` with the audit row out of reach: `row_for/3` seeds
  and returns the same row, but names a record id no audit row carries. The row
  action still runs in the browser, so a test over this host shows a generated
  row-action test failing when the audit row is missing, not when the click is.
  """

  @behaviour AshBrowserTests.Surfaces.Host

  alias AshEnterpriseWeb.E2E.Surfaces

  @impl true
  defdelegate surfaces, to: Surfaces
  @impl true
  defdelegate waivers, to: Surfaces
  @impl true
  defdelegate sign_in(conn, actor, context), to: Surfaces
  @impl true
  defdelegate a2ui_manifest, to: Surfaces
  @impl true
  defdelegate row_action_chain(row_action), to: Surfaces
  @impl true
  defdelegate assert_audit(correlation_id, context), to: Surfaces

  @impl true
  def row_for(surface, row_action, context) do
    surface |> Surfaces.row_for(row_action, context) |> Map.put(:id, Ash.UUID.generate())
  end
end
