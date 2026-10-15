# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEnterprise.Mdm.QualityRules do
  @moduledoc """
  The MDM data-quality rule set (MDM-7, ADR 0053 §10): what makes a golden
  record trustworthy, filed under three controls.

  | # | rule | shape |
  |---|---|---|
  | 1 | `mdm.contact_present` | simple attribute check |
  | 2 | `mdm.provenance_open` | absence semantics (`no_fact` → fail) |
  | 3 | `mdm.freshness` | staleness window, unknown never passes |

  Subjects are golden records (`"person:<uuid>"`). Facts arrive from event
  metadata as JSON.

  Deliberately NOT part of the organization's compliance bundle: the MDM
  projector bundles this module directly
  (`QualityProjector.active_bundle/1`), because `compile_policy_bundle!/1`
  folds every active revision for the org into one bundle, and KYC's
  projector and gap derivation would then read a mixed fact schema.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:mdm_email_present, :boolean,
      missing: :unknown,
      description: "The golden record carries an e-mail address"
    )

    fact(:mdm_source_count, :integer,
      missing: :no_fact,
      description: "How many source identities feed the golden record"
    )

    fact(:mdm_fresh, :boolean,
      missing: :unknown,
      description: "The golden record changed within the freshness window (90 days)"
    )
  end

  rule "goldens carry a contact address",
    id: "mdm.contact_present",
    severity: :high,
    message: "golden record has no e-mail address" do
    fails_when(neg(:customer, :mdm_email_present, true))
    outcome(:noncompliant, gap: "mdm.contact")
  end

  rule "goldens keep provenance open",
    id: "mdm.provenance_open",
    severity: :medium,
    message: "no source identity feeds this golden record" do
    fails_when(has(:customer, :mdm_source_count, 0))
    outcome(:noncompliant, gap: "mdm.provenance")
  end

  rule "goldens are freshly maintained",
    id: "mdm.freshness",
    severity: :low,
    message: "golden record has not changed within the freshness window" do
    # Stale OR unknown (never reviewed) both fail: a record nobody can date
    # is not a fresh one.
    fails_when(neg(:customer, :mdm_fresh, true))
    outcome(:noncompliant, gap: "mdm.freshness")
  end
end
