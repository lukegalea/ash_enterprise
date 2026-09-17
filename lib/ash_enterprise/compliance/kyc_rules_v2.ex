defmodule AshEnterprise.Compliance.KycRulesV2 do
  @moduledoc """
  Revision "2" of the KYC baseline: the replay-testable rule change.

  The diff against revision "1" (`AshEnterprise.Compliance.KycRules`) is one
  line — `kyc.email_domain_migrated` moves from `:low` to `:high`, because
  the e-mail domain migration has run long enough that the compliance office
  escalated it. Every other rule, and the whole fact schema, is unchanged:
  a revision that drifted everywhere would not isolate the thing a rule
  change actually does to findings.

  That thing is: **the same event range replays into different severities
  under the new bundle and into identical outcomes under the old one.**
  `AshEnterprise.Compliance.KycRulesV2Test` pins both halves, and the
  `kyc_findings_v1` projector needs no name bump for it — a severity change
  flows through the same ops. The bump-and-rebuild is for handler changes,
  not rule data.

  Seeded by `AshEnterprise.Compliance.Seed` as `kyc-baseline` revision "2",
  left in `:draft` — activation is a lifecycle decision
  (validate → approve → activate, retire revision 1), exercised by the test
  rather than performed by a seed.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    # --- the subject and their onboarding state -----------------------------
    fact(:status, :atom,
      one_of: [:active, :pending, :suspended],
      description: "Lifecycle state of the projected user"
    )

    fact(:jurisdiction, :atom,
      one_of: [:regulated, :domestic, :unknown],
      description: "Where the subject is onboarded"
    )

    fact(:identity_confirmed, :boolean,
      missing: :unknown,
      description: "Government ID verified; no data means we cannot know"
    )

    fact(:sanctions_cleared, :boolean,
      missing: :unknown,
      description: "Sanctions screening outcome; no data blocks compliance"
    )

    fact(:email_domain, :string, description: "Domain of the subject's e-mail address")

    fact(:risk_tier, :atom,
      one_of: [:low, :medium, :high],
      description: "Risk classification assigned at onboarding"
    )

    fact(:review_completed, :boolean,
      missing: :no_fact,
      description: "Whether the periodic review happened; absence means not yet"
    )

    fact(:open_remedications, :integer,
      missing: :no_fact,
      description: "Count of open remediation items; the aggregate the host supplies"
    )

    # --- the variable join: accounts owned by the subject --------------------
    fact(:account_owner, :atom, description: "The subject an account belongs to")

    fact(:account_balance, :integer,
      missing: :no_fact,
      description: "Balance on the account"
    )
  end

  rule "active subjects must have confirmed identity",
    id: "kyc.identity_confirmed",
    severity: :high,
    message: "identity confirmation outstanding" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :identity_confirmed, true))
    outcome(:noncompliant, gap: "kyc.identity")
  end

  rule "every subject carries a reachable e-mail domain",
    id: "kyc.contact_reachable",
    severity: :low,
    message: "no e-mail domain on file" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :email_domain, "example.com"))
    outcome(:noncompliant, gap: "kyc.contact")
  end

  rule "subjects must sit in a supported jurisdiction",
    id: "kyc.jurisdiction_supported",
    severity: :medium do
    when_requires(has(:customer, :status, :active))
    fails_when(has(:customer, :jurisdiction, :unknown))
    outcome(:noncompliant, gap: "kyc.jurisdiction")
  end

  rule "sanctions screening must clear",
    id: "kyc.sanctions_cleared",
    severity: :critical,
    message: "sanctions screening has not cleared" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :sanctions_cleared, true))
    outcome(:noncompliant, gap: "kyc.sanctions")
  end

  rule "high-risk regulated subjects need enhanced review",
    id: "kyc.enhanced_review",
    severity: :high,
    message: "enhanced review outstanding for a high-risk regulated subject" do
    when_requires(
      has(:customer, :status, :active),
      has(:customer, :jurisdiction, :regulated),
      has(:customer, :risk_tier, :high)
    )

    fails_when(neg(:customer, :review_completed, true))
    outcome(:noncompliant, gap: "kyc.enhanced_review")
  end

  rule "onboarding review must be recorded",
    id: "acct.welcome_review",
    severity: :low,
    message: "onboarding review not recorded" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :review_completed, true))
    outcome(:noncompliant, gap: "kyc.welcome")
  end

  rule "no open remediations on an active subject",
    id: "acct.remediations_closed",
    severity: :medium do
    when_requires(
      has(:customer, :status, :active),
      has(:customer, :open_remedications, 0)
    )

    fails_when(has(:customer, :open_remedications, 1))
    outcome(:noncompliant, gap: "kyc.remediations")
  end

  rule "periodic review completed within the window",
    id: "kyc.review_required",
    severity: :medium,
    message: "periodic review not completed" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :review_completed, true))
    outcome(:noncompliant, gap: "kyc.review")
  end

  rule "suspended subjects hold no balance",
    id: "acct.balance_frozen",
    severity: :low,
    message: "account %{account} holds a balance while suspended" do
    when_requires(
      has(:customer, :status, :suspended),
      has(var(:account), :account_owner, :customer)
    )

    fails_when(neg(var(:account), :account_balance, 0))
    outcome(:noncompliant, gap: "kyc.accounts")
  end

  rule "high-tier subjects are review-first",
    id: "kyc.tier_conflict",
    severity: :high,
    message: "high-tier subject pending review" do
    when_requires(has(:customer, :risk_tier, :high))
    fails_when(neg(:customer, :review_completed, true))
    outcome(:noncompliant, gap: "kyc.tier")
  end

  rule "low-tier subjects are self-certified",
    id: "kyc.tier_low_selfcert",
    severity: :low,
    message: "low-tier subject self-certified" do
    when_requires(has(:customer, :risk_tier, :low))
    fails_when(neg(:customer, :review_completed, false))
    outcome(:noncompliant, gap: "kyc.tier")
  end

  # The v2 change, and the only line that differs from revision 1:
  # severity :low -> :high.
  rule "e-mail domains migrate with the subject",
    id: "kyc.email_domain_migrated",
    severity: :high,
    message: "e-mail domain not yet migrated" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :email_domain, "example.com"))
    outcome(:noncompliant, gap: "kyc.migration")
  end
end
