defmodule AshEnterprise.Canonical.Actions.AgendaDigest do
  @moduledoc """
  `CalendarEvent.agenda_digest`: one agenda window as a few lines of plain
  text, for a terminal transcript (the ACP `calendar` / `today` prompts).

  Reads through the window's own read action as the calling actor, so the
  text and the A2UI table beside it are the same rows under the same
  policies. Times are the operator's wall clock (`LocalTime`); a shredded
  title reads `[shredded]`.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Canonical.CalendarEvent
  alias AshEnterprise.Platform.LocalTime

  @max_lines 40

  @impl true
  def run(input, _opts, context) do
    window = input.arguments[:window] || :today

    case events(window, Ash.Context.to_opts(context)) do
      {:ok, events} -> {:ok, render(window, events)}
      {:error, error} -> {:error, error}
    end
  end

  @doc "The rows of `window`, read as the actor in `opts`."
  def events(window, opts) do
    CalendarEvent
    |> Ash.Query.for_read(window, %{}, opts)
    |> Ash.Query.load([:title, :location, :time_range])
    |> Ash.read(opts)
  end

  @doc "Renders a window's events as text. Public for the Today digest."
  def render(window, []), do: "#{heading(window)} — nothing scheduled."

  def render(window, events) do
    count = length(events)
    noun = if count == 1, do: "event", else: "events"

    lines =
      if window in [:today, :tomorrow] do
        Enum.map(Enum.take(events, @max_lines), &line/1)
      else
        events
        |> Enum.take(@max_lines)
        |> Enum.chunk_by(&LocalTime.day(&1.starts_at))
        |> Enum.flat_map(fn [first | _] = day ->
          [LocalTime.day(first.starts_at) | Enum.map(day, &line/1)]
        end)
      end

    more = if count > @max_lines, do: ["  … and #{count - @max_lines} more"], else: []

    Enum.join(["#{heading(window)} — #{count} #{noun}" | lines ++ more], "\n")
  end

  defp heading(:today), do: "Today · #{LocalTime.day(LocalTime.today())}"
  defp heading(:tomorrow), do: "Tomorrow · #{LocalTime.day(Date.add(LocalTime.today(), 1))}"
  defp heading(:this_week), do: "This week"
  defp heading(:upcoming), do: "Upcoming"

  defp line(event) do
    "  #{event.time_range}  #{event.title}" <> location(event.location) <> status(event.status)
  end

  defp location(nil), do: ""
  defp location(location), do: "  · #{location}"

  defp status(:cancelled), do: "  [cancelled]"
  defp status(:tentative), do: "  [tentative]"
  defp status(_status), do: ""
end
