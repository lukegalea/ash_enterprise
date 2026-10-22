defmodule AshEnterprise.Assistant.Lookups.CalendarEvents do
  @moduledoc """
  `Lookup.calendar_events`: the person's events overlapping a window
  (default `this_week`), narrowed by attendee/organizer and by text.

  Reads `CalendarEvent.read` as the person, with its organizer and attendees
  loaded under the same policies. Title and location are sealed, so the
  text match runs on the decrypted rows, after the read — never in SQL over
  ciphertext. At most #{500} events are scanned and #{30} returned.

  With `as_of` the answer is the calendar as it was known then (PROD-47;
  `CalendarEvent` is temporal, ADR 0049): "what was on my calendar last
  Monday, as of Friday" reads the window as of Friday, before any later
  reschedule or cancellation. An event that has changed since says so, with
  `now` (its time today) or `status_now`. A bare date means the end of that
  day, as in `find_people`. The window itself is still named on today's
  clock, so a past day is best given as a date.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.CalendarEvent

  @scan 500
  @shown 30
  @attendees_shown 8

  @impl true
  def run(input, _opts, context) do
    Support.gated(input, context, &lookup(input.arguments, &1))
  end

  defp lookup(args, opts) do
    with {:ok, as_of} <- as_of(args[:as_of]),
         {:ok, bounds} <- bounds(args[:window]),
         {:ok, events} <- read(bounds, opts ++ as_of_opt(as_of)) do
      matched = Enum.filter(events, &wanted?(&1, args))
      shown = Enum.take(matched, @shown)
      now = since(shown, as_of, opts)

      result = %{
        "window" => Support.window_label(bounds),
        "count" => length(matched),
        "events" => Enum.map(shown, &row(&1, now))
      }

      {:ok, if(as_of, do: Map.put(result, "as_of", DateTime.to_iso8601(as_of)), else: result)}
    else
      {:error, message} when is_binary(message) -> Support.refused(message)
      {:error, error} -> {:error, error}
    end
  end

  defp as_of(value) do
    case Support.as_of(value) do
      {:ok, as_of} -> {:ok, as_of}
      :error -> {:error, "Give as_of as a date (2026-10-16) or a UTC time."}
    end
  end

  defp as_of_opt(nil), do: []
  defp as_of_opt(as_of), do: [as_of: as_of]

  # As of a past moment: the same events as they stand today, by id, so a
  # row can say it has moved or been cancelled since. Read as the person.
  defp since(_events, nil, _opts), do: %{}
  defp since([], _as_of, _opts), do: %{}

  defp since(events, _as_of, opts) do
    ids = Enum.map(events, & &1.id)

    CalendarEvent
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(:when)
    |> Ash.read(opts)
    |> case do
      {:ok, current} -> Map.new(current, &{&1.id, &1})
      {:error, _} -> %{}
    end
  end

  defp wanted?(event, args) do
    Support.matches?(people_terms(event), args[:attendee]) and
      Support.matches?([Support.text(event.title), Support.text(event.location)], args[:text])
  end

  defp bounds(window) do
    case Support.window(window) do
      :none -> Support.window("this_week")
      other -> other
    end
  end

  defp read({from, to}, opts) do
    CalendarEvent
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(starts_at < ^to and ends_at > ^from)
    |> Ash.Query.sort(starts_at: :asc)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load([:when, :organizer_label, :attendee_count, people: [:label]])
    |> Ash.read(opts)
  end

  defp people_terms(event) do
    people = loaded(event.people)

    [Support.text(event.organizer_label)] ++
      Enum.flat_map(people, &[Support.text(&1.label), Support.text(&1.email)])
  end

  defp row(event, now) do
    names =
      event.people
      |> loaded()
      |> Enum.map(&Support.text(&1.label))
      |> Enum.reject(&is_nil/1)

    %{
      "ref" => Support.ref(CalendarEvent, event),
      "title" => Support.clip(event.title, 160),
      "when" => event.when,
      "where" => Support.clip(event.location, 120),
      "organizer" => Support.text(event.organizer_label),
      "attendees" => Enum.take(names, @attendees_shown),
      "attendee_count" => event.attendee_count,
      "status" => event.status
    }
    |> Map.merge(changed_since(event, Map.get(now, event.id)))
    |> Support.compact()
  end

  # Nothing to say when it is unchanged, or read now. Gone today (no longer
  # readable, or its history ended) is said too.
  defp changed_since(_event, nil), do: %{}

  defp changed_since(event, current) do
    moved? =
      DateTime.compare(event.starts_at, current.starts_at) != :eq or
        DateTime.compare(event.ends_at, current.ends_at) != :eq

    %{
      "now" => if(moved?, do: current.when),
      "status_now" => if(current.status != event.status, do: current.status)
    }
  end

  defp loaded(list) when is_list(list), do: list
  defp loaded(_not_loaded), do: []
end
