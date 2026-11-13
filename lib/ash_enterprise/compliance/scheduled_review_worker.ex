defmodule AshEnterprise.Compliance.ScheduledReviewWorker do
  @moduledoc """
  Makes a periodic control's review due: once a day it records, in every organization that
  has a published recipe, one `compliance.review_due` occurrence for each scheduled
  `ash_compliance` process template and the period (week, month, quarter or year) the day
  falls in. A recipe in the `soc2` pack watches for its template's occurrence and opens the
  review (`priv/packs/soc2/`).

  This is the schedule behind a recipe: the recipe engine matches audited writes and has no
  clock of its own, so the clock is this worker (the crontab in `config/config.exs`) and
  the fact it records is an `AshEnterprise.Automation.Occurrence` in the tenant's chain.

  **A period opens one review.** The occurrence's identity is the template and the period,
  so the daily run that finds it already recorded writes nothing, and a missed day is made
  up by the next run, which is in the same period. A recipe that is not published, or a
  tenant with none, starts nothing: the occurrence is only a fact that a review is due.

  A tenant with no published recipe is skipped, so an organization that installed nothing
  collects no occurrences.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  alias AshCompliance.Processes.Templates
  alias AshEnterprise.Automation.Occurrences
  alias AshEnterprise.Bpmn.Subscription

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()
    organizations = Subscription.trigger_tenants()

    for organization <- organizations, template <- scheduled() do
      Occurrences.review_due(
        organization,
        template.key,
        template.frequency,
        period(template.frequency, today)
      )
    end

    {:ok, length(organizations)}
  end

  @doc "The templates that run on a schedule: `ash_compliance`'s, whose trigger is `:schedule`."
  @spec scheduled() :: [map()]
  def scheduled, do: Enum.filter(Templates.all(), &(&1.trigger == :schedule))

  @doc """
  The period `date` falls in for `frequency`, as text that sorts and never repeats:
  `2026-W46` (ISO week), `2026-11`, `2026-Q4`, `2026-H1`, `2026`, or the date itself for a daily one.
  """
  @spec period(String.t(), Date.t()) :: String.t()
  def period("daily", date), do: Date.to_iso8601(date)

  def period("weekly", date) do
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    "#{year}-W#{pad(week)}"
  end

  def period("monthly", date), do: "#{date.year}-#{pad(date.month)}"
  def period("quarterly", date), do: "#{date.year}-Q#{div(date.month - 1, 3) + 1}"
  def period("semiannual", date), do: "#{date.year}-H#{div(date.month - 1, 6) + 1}"
  def period("annual", date), do: Integer.to_string(date.year)

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
