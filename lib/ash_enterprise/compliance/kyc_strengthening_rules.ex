defmodule AshEnterprise.Compliance.KycStrengtheningRules do
  @moduledoc """
  The tenant strengthening layer for the KYC slice: rules a tenant adds that
  tighten the baseline.

  Kept in its own module (and compiled to its own revision) because a layer
  is a property of the *revision*: the compiler resolves precedence per
  contribution, and one module cannot span layers.

  `kyc.mfa_required` is the rule the seeded profile refines — refining a
  strengthening rule is allowed, where refining a mandatory rule is refused.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:status, :atom, one_of: [:active, :pending, :suspended])
    fact(:mfa_enrolled, :boolean, missing: :unknown)
  end

  rule "active subjects must enrol in MFA",
    id: "kyc.mfa_required",
    severity: :medium,
    message: "MFA enrolment outstanding" do
    when_requires(has(:customer, :status, :active))
    fails_when(neg(:customer, :mfa_enrolled, true))
    outcome(:noncompliant, gap: "kyc.mfa")
  end
end
