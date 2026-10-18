defmodule AshEnterprise.BusinessEvents.LedgerBase do
  @moduledoc """
  The base both ledgers stand on: `AshEnterprise.BusinessEvents.Ledger` and
  its simulation twin, `Ledger.SimulationEvent` (ADR 0051).

  `ash_discrete_business_events`' `:ledger` macro emits the twin as a second
  module. Given `simulation_base: {LedgerBase, []}` it builds that module on
  this base instead of a bare `Ash.Resource`, so the real and the simulated
  ledger are the same kind of platform resource: `organization_id` and
  attribute multitenancy, `:user_owned`, the inherited policy set, and
  `AshEnterprise.BusinessEvents.Changes.StampOwner` on every append. Neither
  can hold a row without an owner, and neither is readable past its owner
  (`AshEnterprise.Security.Privilege.owner_only?/1`).

  `audit?: false`, `archival?: false`, `lifecycle?: false` for the reasons
  the ledger's moduledoc gives: an event log is not audited into another
  event log, and a fact is never soft-deleted and has no lifecycle.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      use AshEnterprise.Platform.Resource,
        domain: AshEnterprise.BusinessEvents,
        ownership: :user_owned,
        tenant?: true,
        audit?: false,
        archival?: false,
        lifecycle?: false,
        extra_extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

      changes do
        change AshEnterprise.BusinessEvents.Changes.StampOwner, on: [:create]
      end
    end
  end
end
