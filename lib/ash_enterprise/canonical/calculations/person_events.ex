defmodule AshEnterprise.Canonical.Calculations.PersonEvents do
  @moduledoc """
  A person's calendar, as a short Markdown list for a detail pane: the events
  they organize, nearest first — upcoming ones in start order, then the most
  recent past ones — each with its time on the operator's wall clock.

  Loaded through the `organized_events` relationship under the reading actor's
  policies, so the list never shows an event the reader could not open. A
  shredded title reads `[shredded]`.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Canonical.CalendarEvent

  @limit 12

  @impl true
  def load(_query, _opts, _context) do
    events =
      CalendarEvent
      |> Ash.Query.sort(starts_at: :desc)
      |> Ash.Query.limit(@limit * 4)
      |> Ash.Query.ensure_selected([:starts_at, :ends_at, :status])
      |> Ash.Query.load([:title, :when, :status])

    [organized_events: events]
  end

  @impl true
  def calculate(people, _opts, _context) do
    {:ok, Enum.map(people, &render(&1.organized_events))}
  end

  @doc false
  def render(events) when events in [nil, []], do: "No events they organize."

  def render(events) do
    now = DateTime.utc_now()

    {upcoming, past} = Enum.split_with(events, &(DateTime.compare(&1.ends_at, now) == :gt))

    upcoming
    |> Enum.sort_by(& &1.starts_at, DateTime)
    |> Kernel.++(past)
    |> Enum.take(@limit)
    |> Enum.map_join("\n", &line/1)
  end

  defp line(event) do
    suffix = if event.status == :cancelled, do: " *(cancelled)*", else: ""
    "- **#{event.when}** — #{event.title}#{suffix}"
  end
end
