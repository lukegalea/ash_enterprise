defmodule AshEnterprise.Test.Paper.HazardFollowUp do
  @moduledoc """
  The SYNTHETIC requirement an `activity_summary` is evaluated against before
  it renders: a year whose totals carry the `"Hazard"` category needs a person
  to confirm it was followed up. The generic interview tests run on it.

  `ground_facts/1` emits the year, and `hazard_category_present` only when it
  is true (absence reads as false). The asked fact, `hazard_follow_up_confirmed`,
  is `missing: :unknown`: with no current answer the rule is `:unknown`, which
  blocks the issue and asks; a recorded "no" fires the rule (`:noncompliant`).
  Every triple is about the subject `"activity_year"`.
  """

  use AshRules

  @subject "activity_year"

  combining(:deny_overrides)

  fact_schema do
    fact(:year, :integer, description: "The year the document is about")

    fact(:hazard_category_present, :boolean,
      description: "The year's totals carry a Hazard category"
    )

    fact(:hazard_follow_up_confirmed, :boolean,
      missing: :unknown,
      description: "Was every Hazard entry in this year's totals followed up?"
    )
  end

  rule "a year with hazard entries needs their follow-up confirmed",
    id: "paper.activity_summary.hazard_follow_up",
    severity: :high,
    message:
      "Hazard entries in this year's totals need their follow-up confirmed before it is issued.",
    evidence: ["A follow-up on record for every Hazard entry in the year's totals."] do
    when_requires(has(:activity_year, :hazard_category_present, true))
    fails_when(neg(:activity_year, :hazard_follow_up_confirmed, true))
    outcome(:noncompliant, gap: "paper.hazard_follow_up")
  end

  @doc "The triples the payload itself decides."
  @spec ground_facts(AshPaper.Payload.t()) :: [AshRules.Facts.triple()]
  def ground_facts(%AshPaper.Payload{facts: facts}) do
    year = get_in(facts, ["fields", "year"])
    categories = Enum.map(get_in(facts, ["tables", "totals"]) || [], & &1["category"])

    [
      year && {@subject, :year, year},
      "Hazard" in categories && {@subject, :hazard_category_present, true}
    ]
    |> Enum.filter(& &1)
  end

  @doc "The subject every triple of this requirement is about."
  @spec subject() :: String.t()
  def subject, do: @subject
end
