defmodule AshEnterprise.Compliance.KycRules do
  @moduledoc """
  The KYC rule set for the compliance vertical slice (ADR 0035).

  Subject: a projected user — a person who has arrived from the legacy estate
  (`AshEnterprise.Accounts.ProjectedUser`) and is being onboarded onto the
  platform. Every control below files under a gap that
  `AshCompliance.Resources.ControlMapping` resolves to a control, and the
  finding grain keys on the subject.

  ## The rule census, and why each is here

  This is the POC list from `docs/plans/ash-rules-and-compliance.md` §
  "ash_enterprise integration PR", one rule per line:

  | # | Rule | Exercises |
  |---|------|-----------|
  | 1 | `kyc.identity_confirmed` | simple attribute check |
  | 2 | `kyc.contact_reachable` | simple attribute check |
  | 3 | `kyc.jurisdiction_supported` | simple attribute check |
  | 4 | `kyc.sanctions_cleared` | missing evidence → `:unknown` (`:unknown` absence semantics) |
  | 5 | `kyc.enhanced_review` | multi-fact conjunction (jurisdiction + risk tier) |
  | 6 | `acct.welcome_review` | `no_fact` absence semantics (fires when nothing recorded) |
  | 7 | `acct.remediations_closed` | counter fact supplied by the host (the aggregate) |
  | 8 | `kyc.review_required` | global mandatory layer; waivable with approval |
  | 9 | `acct.balance_frozen` | variable join (`var(:account)`); one finding per binding — the derived facts |
  | 10 | `kyc.tier_conflict` | combining conflict under one control (deny_overrides) |
  | 11 | `kyc.email_domain_migrated` | the replay-testable change: revision 2 patches it |

  Layers: this module compiles to the **global mandatory** baseline (revision
  "1" below). The census' non-waivable floor lives in
  `AshEnterprise.Compliance.KycNonWaivableRules` (`kyc.sanctions_never_waived`,
  waiver refused at compile), the tenant strengthening rule in
  `AshEnterprise.Compliance.KycStrengtheningRules`, and the v2 baseline —
  identical except `kyc.email_domain_migrated` at `:high` — in
  `AshEnterprise.Compliance.KycRulesV2`. A layer is a property of the
  *revision*, not of the rule text, which is why one census spans four modules
  and `AshEnterprise.Compliance.Seed` seeds each as its own revision.

  Value note: fact values arrive from event metadata as JSON. Subjects are
  strings — the opaque wire form of a decoded bundle.
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

  # --- 1-3: simple attribute checks ------------------------------------------

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

  # --- 4: missing evidence is unknown, never a pass ----------------------------

  rule "sanctions screening must clear",
    id: "kyc.sanctions_cleared",
    severity: :critical,
    message: "sanctions screening has not cleared" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :sanctions_cleared, true))
    outcome(:noncompliant, gap: "kyc.sanctions")
  end

  # --- 5: multi-fact conjunction ------------------------------------------------

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

  # --- 6: no_fact absence semantics ---------------------------------------------

  rule "onboarding review must be recorded",
    id: "acct.welcome_review",
    severity: :low,
    message: "onboarding review not recorded" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :review_completed, true))
    outcome(:noncompliant, gap: "kyc.welcome")
  end

  # --- 7: the aggregate (counter supplied by the host) ---------------------------

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

  # --- 8: the global mandatory layer's waivable rule ------------------------------

  rule "periodic review completed within the window",
    id: "kyc.review_required",
    severity: :medium,
    message: "periodic review not completed" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :review_completed, true))
    outcome(:noncompliant, gap: "kyc.review")
  end

  # --- 9: the variable join ------------------------------------------------------
  # The only rule whose failure conditions bind a variable: every account
  # owned by a suspended subject with a non-zero balance produces its own
  # requirement, so `AshRules.Result.derived_facts/1` carries one entry per
  # binding and the finding message names the account.
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

  # --- 11: the combining conflict ---------------------------------------------------------
  # Two rules under one control gap with contradictory conditions: at most one
  # can fire for a given subject, and deny_overrides keeps the finding when
  # both apply but only one fires. Exercises the finding-row combination.
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

  # --- 12: the replay-testable change --------------------------------------------------------
  # v1 of the rule set carries this rule at :low; the v2 revision refines it to
  # :high. Replay tests pin the finding timeline against each revision.
  rule "e-mail domains migrate with the subject",
    id: "kyc.email_domain_migrated",
    severity: :low,
    message: "e-mail domain not yet migrated" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :email_domain, "example.com"))
    outcome(:noncompliant, gap: "kyc.migration")
  end
end
