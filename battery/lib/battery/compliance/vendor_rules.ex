defmodule Battery.Compliance.VendorRules do
  @moduledoc """
  The battery's rule set (ash_rules DSL): an approved vendor review is
  required before onboarding. Compiled to a content-hashed IR bundle,
  serialized into the compliance plane's rule-set revision, and evaluated
  by the projector against facts read off the BIZEV-projected state.

  The absence semantics are the point: `vendor_approved` is
  `missing: :unknown` — an unknown review never collapses to compliant.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:vendor_reviewed, :boolean, missing: :unknown)
    fact(:vendor_approved, :boolean, missing: :unknown)
  end

  rule "an approved vendor review is required before onboarding",
    id: "vendor.approved_required",
    severity: :high,
    message: "vendor review for %{vendor} is not approved" do
    when_requires(has(:vendor, :vendor_reviewed, true))
    fails_when(neg(:vendor, :vendor_approved, true))
    outcome(:noncompliant, gap: "vendor.approved_required")
  end
end
