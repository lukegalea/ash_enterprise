defmodule AshEnterprise.Canonical.CalendarHistory do
  @moduledoc """
  A week of the calendar through time (PROD-47): which events it held, and
  when each one moved.

  `AshEnterprise.Canonical.CalendarEvent` is temporal (ADR 0049). A
  reschedule, a cancellation or a rename closes the version valid until
  then and opens a new one, so the week as it was known at an instant is an
  as-of read, and an event's reschedules are where its consecutive versions
  disagree on `starts_at` or `ends_at` (`AshEnterprise.Platform.TemporalHistory`).

  Every read is the caller's, under the event's policies: an event the
  caller cannot read has no versions here, now or then. The actor is not
  temporal, so their access now decides what the past shows. Only reads.

  The walk costs a read per version per event, so it is bounded to one
  week's events (at most #{200}) and #{50} versions each.
  """

  require Ash.Query

  alias AshEnterprise.Canonical.CalendarEvent
  alias AshEnterprise.Platform.{LocalTime, TemporalHistory}

  @events 200
  @max_versions 50
  @label_title 32

  @typedoc "A moment on the timeline, as `AshA2ui.TimeScrubber` takes it."
  @type mark :: %{
          at: DateTime.t(),
          kind: :rescheduled | :cancelled | :reinstated,
          label: String.t(),
          description: String.t(),
          tone: atom,
          event_id: Ash.UUID.t()
        }

  @doc "The Monday starting the display-zone week that holds `date`."
  @spec week_start(Date.t()) :: Date.t()
  def week_start(%Date{} = date), do: Date.beginning_of_week(date, :monday)

  @doc """
  The events overlapping the display-zone week starting `monday`, as of
  `at` (`nil` for now), in start order.
  """
  @spec week(Date.t(), DateTime.t() | nil, keyword) :: [Ash.Resource.record()]
  def week(%Date{} = monday, at, opts) do
    {from, to} = LocalTime.days(monday, 7)

    CalendarEvent
    |> Ash.Query.for_read(:read, %{}, read_opts(opts) ++ as_of_opt(at))
    |> Ash.Query.filter(starts_at < ^to and ends_at > ^from)
    |> Ash.Query.sort(starts_at: :asc)
    |> Ash.Query.limit(@events)
    |> Ash.read!()
  end

  @doc """
  The history of the week starting `monday`: every version of every event
  in it now or as of `opts[:at]`, and the moments one moved, was cancelled
  or came back, oldest first.
  """
  @spec history(Date.t(), keyword) :: %{
          versions: %{String.t() => [Ash.Resource.record()]},
          marks: [mark]
        }
  def history(%Date{} = monday, opts) do
    seeds = week(monday, nil, opts) ++ if(opts[:at], do: week(monday, opts[:at], opts), else: [])

    versions =
      CalendarEvent
      |> TemporalHistory.versions(seeds, read_opts(opts) ++ [max_versions: @max_versions])
      |> Map.new(fn {id, versions} -> {to_string(id), versions} end)

    marks =
      versions
      |> Map.values()
      |> Enum.flat_map(&marks/1)
      |> Enum.sort_by(& &1.at, DateTime)

    %{versions: versions, marks: marks}
  end

  @doc "The moments in one event's versions (oldest first) where it changed in time or status."
  @spec marks([Ash.Resource.record()]) :: [mark]
  def marks(versions) do
    versions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [before, now] -> change(before, now) end)
  end

  defp change(before, now) do
    cond do
      before.status != :cancelled and now.status == :cancelled ->
        [mark(now, :cancelled, "Cancelled", "#{title(now)}: #{span(now)}", :danger)]

      before.status == :cancelled and now.status != :cancelled ->
        [mark(now, :reinstated, "Back on", "#{title(now)}: #{span(now)}", :secondary)]

      moved?(before, now) ->
        [
          mark(
            now,
            :rescheduled,
            "Moved: " <> clip(title(now)),
            "#{title(now)}: #{span(before)} → #{span(now)}",
            :primary
          )
        ]

      true ->
        []
    end
  end

  defp moved?(before, now) do
    DateTime.compare(before.starts_at, now.starts_at) != :eq or
      DateTime.compare(before.ends_at, now.ends_at) != :eq
  end

  defp mark(version, kind, label, description, tone) do
    %{
      at: TemporalHistory.starts_at(version),
      kind: kind,
      label: label,
      description: description,
      tone: tone,
      event_id: version.id
    }
  end

  defp span(event), do: LocalTime.span(event.starts_at, event.ends_at)

  # A shredded event's title reads as `AshEnterprise.Erasure.Shredded`.
  defp title(%{title: title}) when is_binary(title), do: title
  defp title(_event), do: "An erased event"

  defp clip(text) do
    if String.length(text) > @label_title,
      do: String.slice(text, 0, @label_title - 1) <> "…",
      else: text
  end

  defp read_opts(opts), do: Keyword.take(opts, [:actor, :tenant, :authorize?])

  defp as_of_opt(nil), do: []
  defp as_of_opt(%DateTime{} = at), do: [as_of: at]
end
