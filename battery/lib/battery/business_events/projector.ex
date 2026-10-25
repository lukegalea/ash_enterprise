defmodule Battery.BusinessEvents.Projector do
  @moduledoc """
  The battery's ledger projector (BIZEV-8's shape): kind-only routing over
  the ledger — `project "vendor_review.completed", fn event -> ops end` —
  folding business events into the VendorState projection. Drained with the
  package-owned, per-region `drain/2`.
  """

  use AshDiscreteBusinessEvents.Projections,
    name: "vendor_state_v1",
    event_log: Battery.BusinessEvents.Ledger,
    projection_resource: Battery.BusinessEvents.VendorState

  grain(fn event -> %{region: event.region, subject: event.record_id} end)

  project("vendor_review.completed", fn event ->
    status = event.data["review_status"]

    unless is_binary(status) do
      raise ArgumentError,
            "undigestible #{inspect(event.action)}: data[\"review_status\"] is not a string " <>
              "(subject #{inspect(event.record_id)})"
    end

    [
      {:set, :review_status, status},
      {:set, :reviewer, event.data["reviewer"]}
    ]
  end)
end
