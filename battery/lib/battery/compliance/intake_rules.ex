defmodule Battery.Compliance.IntakeRules do
  @moduledoc """
  Revision 1 of the battery's `intake_rules` rule set (ash_rules DSL): a
  submitted applicant must be identified.

  Serialized into an ash_compliance `RuleSetRevision` and landed active in
  the past by the scheduled-activation scenario; `IntakeRulesRevised` is the
  revision a timer later activates over it.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:submitted, :boolean, missing: :unknown)
    fact(:identified, :boolean, missing: :unknown)
    fact(:within_ceiling, :boolean, missing: :unknown)
  end

  rule "a submitted applicant must be identified",
    id: "intake.identified",
    severity: :high,
    message: "applicant %{applicant} is not identified" do
    when_requires(has(:applicant, :submitted, true))
    fails_when(neg(:applicant, :identified, true))
    outcome(:noncompliant, gap: "intake.identified")
  end
end
