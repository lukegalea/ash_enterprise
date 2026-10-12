defmodule AshEnterprise.Agents.MorningBriefScheduler do
  @moduledoc """
  The daily morning brief: from 06:30 on the display zone's clock, every
  person who owns an active Google Calendar linked account gets the day's
  brief composed and waiting for their approval on Today.

  ## When it runs, and why it ticks

  Cron fires every fifteen minutes in UTC (`config :ash_enterprise, Oban`).
  Each tick asks the display zone (`AshEnterprise.Platform.LocalTime`,
  `DISPLAY_TIME_ZONE`) what the local time is and does nothing before
  `compose_at` (default `06:30`, `config :ash_enterprise, :morning_brief_compose_at`).
  From then until midnight, each tick enqueues a compose for anyone whose
  brief for the local day has not been enqueued yet.

  Not a cron entry at 06:30 in the display zone, for three reasons:

    * the zone is runtime config (`DISPLAY_TIME_ZONE`, read in
      `config/runtime.exs`) while the crontab is compile-time config, and an
      Oban `:timezone` also needs a global `:elixir, :time_zone_database`
      this application does not set (`LocalTime` names `Tz` explicitly);
    * a fixed UTC hour drifts by an hour across daylight saving;
    * a node that was down at 06:30 still briefs the day when it comes back
      (the dogfood instance restarts often), instead of skipping it.

  Toronto's offset is a whole number of hours, so the 06:30 tick lands on the
  minute; a zone with a :15/:45 offset would run within fifteen minutes.

  ## Who

  `LinkedAccount.active_for_integration("google-calendar")`, read as the
  `oban` system actor across tenants: active, unblocked calendar accounts —
  the population with a calendar to brief. One job per owner per tenant per
  day (`AshEnterprise.Agents.MorningBriefWorker` is unique on all three in
  every job state), so the fifteen-minute ticks after the first collapse into
  it. The job composes as the owner (`MorningBrief.compose_today`), under the
  owner's policies; this scheduler reads ids and nothing else.

  Args are empty; the result is counts only (Iron Laws #08/#09).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 60]

  alias AshEnterprise.Agents.MorningBriefWorker
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.{LocalTime, SystemActor}

  @integration "google-calendar"
  @default_compose_at ~T[06:30:00]

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:ok, enqueue(LocalTime.now())}

  @doc """
  For a local wall-clock instant, enqueue the day's composes — or nothing
  before `compose_at/0`. Returns `%{brief_date:, owners:, enqueued:,
  already_enqueued:}`, or `%{brief_date:, waiting_until:}` before the hour.
  """
  @spec enqueue(DateTime.t()) :: map()
  def enqueue(%DateTime{} = local_now) do
    date = DateTime.to_date(local_now)

    if Time.compare(DateTime.to_time(local_now), compose_at()) == :lt do
      %{brief_date: date, waiting_until: compose_at()}
    else
      owners = owners()
      results = Enum.map(owners, &(&1 |> job(date) |> Oban.insert()))

      %{
        brief_date: date,
        owners: length(owners),
        enqueued: Enum.count(results, &match?({:ok, %{conflict?: false}}, &1)),
        already_enqueued: Enum.count(results, &match?({:ok, %{conflict?: true}}, &1))
      }
    end
  end

  @doc "The local time briefs are composed from. `config :ash_enterprise, :morning_brief_compose_at`."
  @spec compose_at() :: Time.t()
  def compose_at do
    case Application.get_env(:ash_enterprise, :morning_brief_compose_at, @default_compose_at) do
      %Time{} = time -> time
      iso when is_binary(iso) -> Time.from_iso8601!(iso)
    end
  end

  # `{owner_id, organization_id}` once each, however many calendar accounts a
  # person has linked in a tenant.
  defp owners do
    @integration
    |> LinkedAccount.active_for_integration!(actor: SystemActor.oban())
    |> Enum.map(&{&1.owner_id, &1.organization_id})
    |> Enum.uniq()
  end

  defp job({owner_id, organization_id}, date) do
    MorningBriefWorker.new(%{
      "user_id" => owner_id,
      "organization_id" => organization_id,
      "brief_date" => Date.to_iso8601(date)
    })
  end
end
