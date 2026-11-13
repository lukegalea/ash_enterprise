defmodule AshEnterprise.Automation.Incidents do
  @moduledoc """
  The only writer of `AshEnterprise.Automation.Incident`: what an alert occurrence means for
  the incidents of the tenant it was recorded in.

  `track/1` runs inside the transaction that records the occurrence
  (`AshEnterprise.Automation.Changes.TrackIncident`), as the `oban` system actor, so an alert
  and what it did to an incident commit together or not at all. A failure here fails the
  recording, and the sender (the alert webhook's relay) delivers it again.

  ## Open, join or close

  An `alert.firing` occurrence opens an incident for its key, or joins the one already open.
  An open incident whose triage has finished (a triage run on it that is no longer running:
  someone resolved it or it was cancelled) is closed as `triage_concluded` first, and the
  alert opens a new one, so an alert after the people on call said "resolved" is a new
  incident, not a footnote to a closed one. An `alert.resolved` occurrence closes the open
  incident for its key as `alert_resolved`; with none open it does nothing.

  ## Series

  One rule fires once per label set, and a provider that says so gives each alert a
  `series` (SigNoz's fingerprint). The open incident keeps the series still firing
  (`Incident.firing_series`): a firing adds its series, and a resolution takes its series out
  and closes the incident only when none is left. Otherwise the first series to resolve
  would close the incident while the others still fire, and their renotifications, replays
  of alerts already recorded, would never reach here to open it again. A new incident opened
  after a concluded triage carries the series the closed one still had firing. An alert
  with no series closes the incident on resolving.

  An occurrence of any other type, or an alert with no provider or no rule to key it by, does
  nothing.

  ## The key

  `"<provider>:<rule id>"`, or `"<provider>:<alert name>"` when the provider gives no rule
  id. The same rule firing again is the same incident; two rules are two incidents.

  ## One open incident per key

  Two alerts for one key recorded at once must not open two incidents. The read-decide-write
  takes a transaction-scoped advisory lock on the tenant and key, and a partial unique index
  (`one_open_per_key`) holds if anything ever writes around it.
  """

  require Ash.Query

  alias AshEnterprise.Automation
  alias AshEnterprise.Automation.{Incident, Occurrence}
  alias AshEnterprise.Bpmn.Instance
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo

  @firing "alert.firing"
  @resolved "alert.resolved"

  @doc "The occurrence type an alert that fires is recorded as."
  @spec firing() :: String.t()
  def firing, do: @firing

  @doc "The occurrence type an alert that resolves is recorded as."
  @spec resolved() :: String.t()
  def resolved, do: @resolved

  @doc """
  The incident key for an alert occurrence's `data`, or `nil` when it has no provider or no
  rule to key it by.
  """
  @spec key(map()) :: String.t() | nil
  def key(data) when is_map(data) do
    provider = field(data, "provider")
    rule = field(data, "rule_id") || field(data, "alertname")

    if provider && rule, do: String.slice(provider <> ":" <> rule, 0, 200), else: nil
  end

  def key(_data), do: nil

  @doc """
  What `occurrence` does to its tenant's incidents. Call inside the transaction that
  recorded it. Returns `{:ok, :opened | :joined | :series_resolved | :closed | :none}` or
  `{:error, error}`.
  """
  @spec track(Occurrence.t()) ::
          {:ok, :opened | :joined | :series_resolved | :closed | :none} | {:error, term()}
  def track(%Occurrence{type: type, data: data, organization_id: tenant} = occurrence)
      when type in [@firing, @resolved] and is_binary(tenant) do
    case key(data) do
      nil -> {:ok, :none}
      key -> locked(tenant, key, fn -> decide(type, key, occurrence) end)
    end
  end

  def track(_occurrence), do: {:ok, :none}

  defp decide(@firing, key, occurrence) do
    case open_incident(occurrence.organization_id, key) do
      nil -> open(key, occurrence, [])
      incident -> open_or_join(incident, triage_concluded?(incident), key, occurrence)
    end
  end

  defp decide(@resolved, key, occurrence) do
    case open_incident(occurrence.organization_id, key) do
      nil -> {:ok, :none}
      incident -> resolve(incident, series(occurrence.data))
    end
  end

  # The series that resolved leaves the incident; the incident closes when none is left. A
  # resolution with no series, or of the last series, closes it.
  defp resolve(incident, series) do
    firing = incident.firing_series || []

    cond do
      is_nil(series) or firing -- [series] == [] ->
        with({:ok, _} <- close(incident, :alert_resolved), do: {:ok, :closed})

      series in firing ->
        with {:ok, _} <-
               Automation.resolve_incident_series(
                 incident,
                 series,
                 opts(incident.organization_id)
               ),
             do: {:ok, :series_resolved}

      # A series this incident never saw fire (one that fired under an incident closed
      # since): the ones it did see are still firing.
      true ->
        {:ok, :none}
    end
  end

  defp open_or_join(incident, true = _concluded?, key, occurrence) do
    with {:ok, _closed} <- close(incident, :triage_concluded),
         do: open(key, occurrence, incident.firing_series || [])
  end

  defp open_or_join(incident, false = _concluded?, _key, occurrence),
    do: join(incident, occurrence)

  defp open(key, occurrence, still_firing) do
    data = occurrence.data
    firing = Enum.uniq(still_firing ++ List.wrap(series(data)))

    %{
      key: key,
      title: field(data, "alertname"),
      severity: field(data, "severity"),
      category: field(data, "category"),
      provider: field(data, "provider"),
      opened_by_occurrence_id: occurrence.id,
      firing_series: firing,
      at: occurrence.time
    }
    |> Automation.open_incident(opts(occurrence.organization_id))
    |> case do
      {:ok, _incident} -> {:ok, :opened}
      error -> error
    end
  end

  defp join(incident, occurrence) do
    case Automation.join_incident(
           incident,
           %{at: occurrence.time, series: series(occurrence.data)},
           opts(incident.organization_id)
         ) do
      {:ok, _incident} -> {:ok, :joined}
      error -> error
    end
  end

  defp close(incident, reason),
    do: Automation.close_incident(incident, reason, opts(incident.organization_id))

  defp open_incident(tenant, key) do
    Incident
    |> Ash.Query.filter(key == ^key and status == :open)
    |> Ash.read_one!(opts(tenant))
  end

  # A triage run on the incident that is no longer running. An incident with no run at all
  # (no recipe published, or the sweep has not reached it yet) is still open.
  defp triage_concluded?(incident) do
    Instance
    |> Ash.Query.filter(subject_id == ^incident.id and status != :running)
    |> Ash.exists?(opts(incident.organization_id))
  end

  defp opts(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  # Raw SQL by design: an advisory lock is not a domain read or write (the ash-discipline
  # exception for advisory locks, as `AshEnterprise.BusinessEvents.Recorder` takes one). The
  # transaction joins the occurrence's own, so the lock is held until it commits.
  defp locked(tenant, key, fun) do
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "incident:" <> tenant <> ":" <> key
      ])

      case fun.() do
        {:ok, result} -> result
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  # `data` as written: string keys from a webhook, atom keys from code that built it.
  @fields %{
    "provider" => :provider,
    "rule_id" => :rule_id,
    "alertname" => :alertname,
    "severity" => :severity,
    "category" => :category,
    "series" => :series
  }

  defp series(data), do: field(data, "series")

  defp field(data, name),
    do: text(Map.get(data, name) || Map.get(data, Map.fetch!(@fields, name)))

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, 120)
    end
  end

  defp text(_value), do: nil
end
