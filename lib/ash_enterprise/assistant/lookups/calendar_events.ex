defmodule AshEnterprise.Assistant.Lookups.CalendarEvents do
  @moduledoc """
  `Lookup.calendar_events`: the person's events overlapping a window
  (default `this_week`), narrowed by attendee/organizer and by text.

  Reads `CalendarEvent.read` as the person, with its organizer and attendees
  loaded under the same policies. Title and location are sealed, so the
  text match runs on the decrypted rows, after the read — never in SQL over
  ciphertext. At most #{500} events are scanned and #{30} returned.
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
    with {:ok, bounds} <- bounds(args[:window]),
         {:ok, events} <- read(bounds, opts) do
      matched = Enum.filter(events, &wanted?(&1, args))

      {:ok,
       %{
         "window" => Support.window_label(bounds),
         "count" => length(matched),
         "events" => matched |> Enum.take(@shown) |> Enum.map(&row/1)
       }}
    else
      {:error, message} when is_binary(message) -> Support.refused(message)
      {:error, error} -> {:error, error}
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

  defp row(event) do
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
    |> Support.compact()
  end

  defp loaded(list) when is_list(list), do: list
  defp loaded(_not_loaded), do: []
end
