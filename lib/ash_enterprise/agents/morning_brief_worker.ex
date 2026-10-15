defmodule AshEnterprise.Agents.MorningBriefWorker do
  @moduledoc """
  Composes one person's morning brief for one day, as that person:

      %{"user_id" => uuid, "organization_id" => uuid, "brief_date" => "2026-10-12"}

  Enqueued by `AshEnterprise.Agents.MorningBriefScheduler`. `perform/1` loads
  the user with their precomputed `ActorContext` (the calendar sync's loader,
  `AshEnterprise.Integration.Calendar.ActorLoader`: the population is calendar
  owners, and an inactive owner is refused there) and calls
  `MorningBrief.compose_today` as them — the brief is theirs, created under
  their policies, and the process records them as its starter.

  ## Idempotency (Iron Law #07)

  Unique on `(user_id, organization_id, brief_date)` in **every** job state,
  so a day gets one job per owner however many ticks enqueue it; a retry
  re-runs `compose_today`, which leaves a day that already has the owner's
  brief alone. A day that is no longer today when the job runs (a backlog
  after an outage) is cancelled rather than briefed late.

  Errors persisted by Oban are structural strings: an Ash error from a failed
  write can quote what it was writing.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:user_id, :organization_id, :brief_date],
      states: :all
    ]

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Integration.Calendar.ActorLoader
  alias AshEnterprise.Platform.LocalTime

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "organization_id" => organization_id, "brief_date" => day}
      }) do
    with {:ok, date} <- Date.from_iso8601(day),
         :ok <- current(date),
         {:ok, actor} <- ActorLoader.load(user_id, organization_id) do
      compose(date, actor, organization_id)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Oban.Job{}),
    do: {:cancel, "morning brief job requires user_id, organization_id and brief_date"}

  defp current(date) do
    if Date.compare(date, LocalTime.today()) == :eq, do: :ok, else: {:error, :not_today}
  end

  defp compose(date, actor, organization_id) do
    case MorningBrief.compose_today(%{brief_date: date}, actor: actor, tenant: organization_id) do
      {:ok, _status_line} ->
        :ok

      {:error, error} ->
        case Ash.Error.to_error_class(error) do
          %Ash.Error.Forbidden{} -> {:cancel, :forbidden_by_policy}
          class -> {:error, "morning brief: compose failed (#{inspect(class.__struct__)})"}
        end
    end
  rescue
    exception -> {:error, "morning brief: raised #{inspect(exception.__struct__)}"}
  end
end
