defmodule AshEnterprise.Canonical.Projections.Gmail.ZoneGate do
  @moduledoc """
  Zone admission for the Gmail projector (ADR 0042): may this landed message
  be projected into the canonical model?

  `AshEnterprise.Canonical.Projections.Gmail` asks once per landed record and
  projects only the records admitted. The gate is configured, never an
  argument:

      config :ash_enterprise, AshEnterprise.Canonical.Projections.Gmail,
        zone_gate: MyZoneAdmission

  The default, `AshEnterprise.Canonical.Projections.Gmail.DenyAll`, admits
  nothing. Gmail content is personal data, and ADR 0042's rule is that a
  record whose residency restriction is not known is refused until tagged; the
  admission check against each item's residency tag is not built yet, so the
  honest default is to refuse everything. The integration step points
  `:zone_gate` at the real check once it exists.
  """

  @doc """
  Admit or refuse one landed record. `source` is the landed row (at least
  `external_id`, `raw_payload` and `source_metadata`, whose
  `"linked_account_id"` names the account it came through); `context` is the
  projection's replay context (`owner_id`, `tenant_id`).
  """
  @callback admit(source :: map(), context :: map()) :: :ok | {:deny, atom()}
end
