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
  recorded it. Returns `{:ok, :opened | :joined | :closed | :none}` or `{:error, error}`.
  """
  @spec track(Occurrence.t()) :: {:ok, :opened | :joined | :closed | :none} | {:error, term()}
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
      nil -> open(key, occurrence)
      incident -> open_or_join(incident, triage_concluded?(incident), key, occurrence)
    end
  end

  defp decide(@resolved, key, occurrence) do
    case open_incident(occurrence.organization_id, key) do
      nil -> {:ok, :none}
      incident -> with({:ok, _} <- close(incident, :alert_resolved), do: {:ok, :closed})
    end
  end

  defp open_or_join(incident, true = _concluded?, key, occurrence) do
    with {:ok, _closed} <- close(incident, :triage_concluded), do: open(key, occurrence)
  end

  defp open_or_join(incident, false = _concluded?, _key, occurrence),
    do: join(incident, occurrence)

  defp open(key, occurrence) do
    data = occurrence.data

    %{
      key: key,
      title: field(data, "alertname"),
      severity: field(data, "severity"),
      category: field(data, "category"),
      provider: field(data, "provider"),
      opened_by_occurrence_id: occurrence.id,
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
           %{at: occurrence.time},
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
    "category" => :category
  }

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
