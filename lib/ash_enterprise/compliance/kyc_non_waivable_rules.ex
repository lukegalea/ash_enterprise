defmodule AshEnterprise.Compliance.KycNonWaivableRules do
  @moduledoc """
  The non-waivable floor for the KYC slice: the rules no approval may ever
  excuse.

  Kept in its own module (and compiled to its own revision) because a layer
  is a property of the *revision*: this one seeds at `:global_non_waivable`,
  and `AshCompliance.Compiler` refuses any waiver that targets a rule
  declared here — the refusal, verbatim, being the point of the exercise:

  > waiver for rule "kyc.sanctions_never_waived" refused: the rule is
  > declared in the non-waivable global layer and can never be waived

  The fact declarations must match the baseline's (`AshCompliance.Compiler`
  merges fact schemas across contributing revisions and refuses conflicting
  declarations), so `status` and `sanctions_cleared` are spelled exactly as
  `AshEnterprise.Compliance.KycRules` spells them.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:status, :atom,
      one_of: [:active, :pending, :suspended],
      description: "Lifecycle state of the projected user"
    )

    fact(:sanctions_cleared, :boolean,
      missing: :unknown,
      description: "Sanctions screening outcome; no data blocks compliance"
    )
  end

  rule "sanctions clearance can never be waived",
    id: "kyc.sanctions_never_waived",
    severity: :critical,
    message: "sanctions clearance missing and cannot be waived" do
    when_requires(has(:customer, :status, :suspended))
    fails_when(neg(:customer, :sanctions_cleared, true))
    outcome(:noncompliant, gap: "kyc.sanctions_floor")
  end
end
