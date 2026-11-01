defmodule AshEnterprise.Assistant.Lookups.ActivityCounts do
  @moduledoc """
  `Lookup.ActivityCount.count_activity`: counts of messages, calendar events
  or conversations over a window (default `last_30_days`), grouped by person,
  local day or source. The first row, `all`, is the total; the groups follow
  it, at most #{25}.

  Counted from the same reads the other tools make, as the person — so a
  count is over exactly the rows they may read, never a total across
  owners, tenants or zones. Up to #{5000} rows are counted; past that the
  `all` row says `truncated` rather than presenting a partial total as whole.

  | metric | person | day | source |
  |---|---|---|---|
  | messages | the sender (`me` for sent) | the day sent | gmail / slack |
  | events | each attendee, once per event | the day it starts | the calendar |
  | conversations | each participant, once per thread | the day of latest activity | gmail / slack |
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.{Conversations, Support}
  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message}
  alias AshEnterprise.Platform.LocalTime

  @scan 5000
  @shown 25

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn opts ->
      metric = query.arguments[:metric]
      group_by = query.arguments[:group_by]

      with {:ok, bounds} <- bounds(query.arguments[:window]),
           {:ok, rows} <- scan(metric, bounds, opts) do
        {:ok, [total(rows, bounds) | groups(rows, metric, group_by)]}
      end
    end)
  end

  defp total(rows, bounds) do
    Support.row(Lookup.ActivityCount, %{
      key: "all",
      count: length(rows),
      window: Support.window_label(bounds),
      truncated: length(rows) >= @scan
    })
  end

  defp groups(rows, metric, group_by) do
    rows
    |> Enum.flat_map(&keys(metric, group_by, &1))
    |> Enum.frequencies()
    |> order(group_by)
    |> Enum.take(@shown)
    |> Enum.map(fn {key, count} ->
      Support.row(Lookup.ActivityCount, %{key: key, count: count})
    end)
  end

  defp bounds(window) do
    case Support.window(window) do
      :none -> Support.window("last_30_days")
      other -> other
    end
  end

  defp scan(:messages, {from, to}, opts) do
    Message
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(sent_at >= ^from and sent_at < ^to)
    |> Ash.Query.sort(sent_at: :desc)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load([:sender_label])
    |> Ash.read(opts)
  end

  defp scan(:events, {from, to}, opts) do
    CalendarEvent
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(starts_at < ^to and ends_at > ^from)
    |> Ash.Query.sort(starts_at: :asc)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load(people: [:label])
    |> Ash.read(opts)
  end

  defp scan(:conversations, {from, to}, opts) do
    Conversation
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(exists(messages, sent_at >= ^from and sent_at < ^to))
    |> Ash.Query.sort(last_message_at: :desc_nils_last)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load([:last_message_at, people: [:label]])
    |> Ash.read(opts)
  end

  defp keys(:messages, :person, message), do: [Conversations.from(message)]
  defp keys(:messages, :day, message), do: [day(message.sent_at)]
  defp keys(:messages, :source, message), do: [message.external_system || "unknown"]

  defp keys(:events, :person, event), do: labels(event.people)
  defp keys(:events, :day, event), do: [day(event.starts_at)]
  defp keys(:events, :source, event), do: [event.external_system || "calendar"]

  defp keys(:conversations, :person, thread), do: labels(thread.people)
  defp keys(:conversations, :day, thread), do: [day(thread.last_message_at)]
  defp keys(:conversations, :source, thread), do: [thread.external_system || "unknown"]

  defp labels(people) when is_list(people) do
    people
    |> Enum.map(&(Support.text(&1.label) || "unnamed"))
    |> Enum.uniq()
  end

  defp labels(_not_loaded), do: []

  defp day(nil), do: "unknown"

  defp day(datetime) do
    date = datetime |> LocalTime.to_local() |> DateTime.to_date()
    "#{Date.to_iso8601(date)} #{Calendar.strftime(date, "%a")}"
  end

  # Days read in order; everything else most-first.
  defp order(counts, :day), do: Enum.sort_by(counts, fn {key, _} -> key end)
  defp order(counts, _group_by), do: Enum.sort_by(counts, fn {key, n} -> {-n, key} end)
end
