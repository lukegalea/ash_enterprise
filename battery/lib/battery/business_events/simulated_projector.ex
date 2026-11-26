defmodule Battery.BusinessEvents.SimulatedProjector do
  @moduledoc """
  The simulation projection of the vendor review: it drains the twin only, and
  its grain names the run (`simulation_projection: true`).
  """

  use AshDiscreteBusinessEvents.Projections,
    name: "vendor_state_simulated_v1",
    event_log: Battery.BusinessEvents.Ledger,
    projection_resource: Battery.BusinessEvents.SimulatedVendorState,
    simulation_projection: true

  grain(fn event ->
    %{region: event.region, subject: event.record_id, simulation_run: event.simulation_run}
  end)

  project("vendor_review.completed", fn event ->
    [{:set, :review_status, event.data["review_status"]}]
  end)
end
