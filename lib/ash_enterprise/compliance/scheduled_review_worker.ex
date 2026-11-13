defmodule AshEnterprise.Compliance.ScheduledReviewWorker do
  @moduledoc """
  Makes a periodic control's review due: once a day it records, in every organization where a
  published recipe watches for it, one `compliance.review_due` occurrence for each scheduled
  `ash_compliance` process template and the period (week, month, quarter or year) the day
  falls in. A recipe in the `soc2` pack watches for its template's occurrence and opens the
  review (`priv/packs/soc2/`).

  This is the schedule behind a recipe: the recipe engine matches audited writes and has no
  clock of its own, so the clock is this worker (the crontab in `config/config.exs`) and
  the fact it records is an `AshEnterprise.Automation.Occurrence` in the tenant's chain.

  ## Only for a template a published recipe names

  A template's occurrence is recorded in an organization only once a published, enabled
  recipe there names the template in its guard (`"policy_review_acknowledgement"`, as the
  `soc2` pack's guards do: `data.data.template = "policy_review_acknowledgement"`). A recipe
  fires only on events after it exists, so an occurrence recorded before its recipe was
  published would sit behind the recipe's cursor and, since the period's occurrence is
  recorded once, the review would not open until the next period: for an annual template,
  most of a year. Recording a template only for the tenants listening for it means the first
  run after a recipe is published records that period's occurrence, and the recipe sees it.

  **A period opens one review.** The occurrence's identity is the template and the period,
  so the daily run that finds it already recorded writes nothing, and a missed day is made
  up by the next run, which is in the same period. An organization with no recipe naming a
  template collects no occurrence for it.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  alias AshCompliance.Processes.Templates
  alias AshEnterprise.Automation.Occurrences
  alias AshEnterprise.Bpmn.Subscription
  alias AshEnterprise.Platform.SystemActor

  require Ash.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()
    templates = scheduled()
    listening = listening(templates)

    for {organization, keys} <- listening,
        template <- templates,
        template.key in keys do
      Occurrences.review_due(
        organization,
        template.key,
        template.frequency,
        period(template.frequency, today)
      )
    end

    {:ok, map_size(listening)}
  end

  @doc """
  For each organization with a published, enabled recipe that names one of `templates` in its
  guard, the keys of the templates named. Organizations naming none are left out.
  """
  @spec listening([map()]) :: %{Ash.UUID.t() => [String.t()]}
  def listening(templates \\ scheduled()) do
    Subscription
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status == :published and enabled == true and kind == :message)
    |> Ash.Query.select([:organization_id, :guard_feel])
    |> Ash.read!(actor: SystemActor.process(), tenant: nil)
    |> Enum.reject(&is_nil(&1.organization_id))
    |> Enum.group_by(& &1.organization_id, & &1.guard_feel)
    |> Map.new(fn {organization, guards} -> {organization, named(templates, guards)} end)
    |> Map.reject(fn {_organization, keys} -> keys == [] end)
  end

  defp named(templates, guards),
    do: for(t <- templates, Enum.any?(guards, &names?(&1, t.key)), do: t.key)

  # The template's key as a FEEL string literal in the guard.
  defp names?(guard, key) when is_binary(guard), do: String.contains?(guard, ~s("#{key}"))
  defp names?(_guard, _key), do: false

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
