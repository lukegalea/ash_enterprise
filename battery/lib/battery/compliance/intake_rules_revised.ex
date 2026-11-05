defmodule Battery.Compliance.IntakeRulesRevised do
  @moduledoc """
  Revision 2 of the battery's `intake_rules` rule set: revision 1's rule plus
  a ceiling on the submitted amount. Activating it (at a declared instant)
  succeeds revision 1, so an applicant over the ceiling stops passing from
  that instant on, and only from that instant on.
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

  rule "a submitted amount must be under the ceiling",
    id: "intake.within_ceiling",
    severity: :medium,
    message: "applicant %{applicant} is over the ceiling" do
    when_requires(has(:applicant, :submitted, true))
    fails_when(neg(:applicant, :within_ceiling, true))
    outcome(:noncompliant, gap: "intake.within_ceiling")
  end
end
