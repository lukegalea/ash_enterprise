defmodule AshEnterprise.Agents.Today do
  @moduledoc """
  The operator's day at a glance — what the Today surface's reports and the
  ACP `today` prompt are made of. Every number is an ordinary read as the
  calling actor, under their policies; nothing here holds data of its own.

    * `agenda/1` — today's events (time, title, where, status);
    * `pulse/1` — approvals waiting, the next event, sync health per linked
      account, and whether the inbox and Slack are flowing;
    * `digest/1` — all of it, plus the latest morning brief, as text.

  A read that fails (a missing grant, say) reports `unavailable` for its line
  rather than failing the whole day: a person opening Today wants the rest of
  their day even when one source is down.
  """

  require Ash.Query

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Bpmn.Actions.QueueDigest
  alias AshEnterprise.Canonical.Actions.AgendaDigest
  alias AshEnterprise.Canonical.{Admission, CalendarEvent, Conversation}
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.LocalTime

  @doc "Today's events as report rows."
  @spec agenda(keyword()) :: {:ok, [map()]} | {:error, term()}
  def agenda(opts) do
    with {:ok, events} <- AgendaDigest.events(:today, opts) do
      {:ok,
       Enum.map(events, fn event ->
         %{
           time: event.time_range,
           title: to_string(event.title),
           where: event.location && to_string(event.location),
           status: status(event.status)
         }
       end)}
    end
  end

  @doc "The day's signals as report rows: `%{signal:, value:}`."
  @spec pulse(keyword()) :: {:ok, [map()]}
  def pulse(opts) do
    rows =
      [
        approvals_row(opts),
        next_event_row(opts)
      ] ++ account_rows(opts) ++ [inbox_row(:gmail, opts), inbox_row(:slack, opts)]

    {:ok, rows}
  end

  @doc "The whole day as text: brief, agenda, signals."
  @spec digest(keyword()) :: {:ok, String.t()}
  def digest(opts) do
    brief =
      case latest_brief(opts) do
        {:ok, %MorningBrief{} = brief} ->
          "#{brief.draft_text || "Morning brief for #{brief.brief_date} — not composed yet."}\n" <>
            "Status: #{brief_status(brief.status)}" <>
            if(brief.status == :pending_approval,
              do: " — say `approve brief` or `reject brief`.",
              else: ""
            )

        _none ->
          "No morning brief yet today."
      end

    agenda =
      case AgendaDigest.events(:today, opts) do
        {:ok, events} -> AgendaDigest.render(:today, events)
        {:error, _} -> "Today — agenda unavailable."
      end

    {:ok, pulse} = pulse(opts)
    signals = Enum.map(pulse, &"  #{&1.signal}: #{&1.value}")

    {:ok, Enum.join([agenda, "", brief, "", "Pulse" | signals], "\n")}
  end

  @doc "The actor's most recent morning brief, with its draft rendered."
  def latest_brief(opts) do
    MorningBrief
    |> Ash.Query.for_read(:latest, %{}, opts)
    |> Ash.Query.load(:draft_text)
    |> Ash.Query.limit(1)
    |> Ash.read_one(opts)
  end

  @doc "How a brief's status reads."
  def brief_status(:pending_approval), do: "waiting for your approval"
  def brief_status(:approved), do: "approved"
  def brief_status(:rejected), do: "rejected"

  defp approvals_row(opts) do
    value =
      case QueueDigest.awaiting(opts) do
        {:ok, []} -> "none waiting"
        {:ok, [_]} -> "1 waiting"
        {:ok, tasks} -> "#{length(tasks)} waiting"
        {:error, _} -> "unavailable"
      end

    %{signal: "Approvals", value: value}
  end

  defp next_event_row(opts) do
    value =
      CalendarEvent
      |> Ash.Query.for_read(:upcoming, %{}, opts)
      |> Ash.Query.filter(status != :cancelled)
      |> Ash.Query.load([:title, :when])
      |> Ash.Query.limit(1)
      |> Ash.read(opts)
      |> case do
        {:ok, [event]} -> "#{event.when} — #{event.title}"
        {:ok, []} -> "nothing in the next two weeks"
        {:error, _} -> "unavailable"
      end

    %{signal: "Next up", value: value}
  end

  defp account_rows(opts) do
    LinkedAccount
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.load([:provider, :health, :last_sync])
    |> Ash.Query.sort(:provider_config_key)
    |> Ash.read(opts)
    |> case do
      {:ok, []} ->
        [%{signal: "Syncs", value: "no linked accounts"}]

      {:ok, accounts} ->
        Enum.map(accounts, fn account ->
          %{signal: "#{account.provider} sync", value: "#{account.health} · #{account.last_sync}"}
        end)

      {:error, _} ->
        [%{signal: "Syncs", value: "unavailable"}]
    end
  end

  defp inbox_row(system, opts) do
    label = if system == :gmail, do: "Inbox", else: "Slack"

    value =
      Conversation
      |> Ash.Query.for_read(system, %{}, opts)
      |> Ash.count(opts)
      |> case do
        {:ok, 0} ->
          if Admission.held?(system),
            do: "held back until zone admission (ADR 0042)",
            else: "no conversations yet"

        {:ok, 1} ->
          "1 conversation"

        {:ok, n} ->
          "#{n} conversations"

        {:error, _} ->
          "unavailable"
      end

    %{signal: label, value: value}
  end

  defp status(:confirmed), do: ""
  defp status(other), do: to_string(other)

  @doc false
  def today_label, do: LocalTime.day(LocalTime.today())
end
