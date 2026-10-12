defmodule AshEnterprise.Canonical.Calculations.NextEvent do
  @moduledoc """
  The next not-cancelled event a person organizes, for a directory row:
  `Tue 13 Oct · 10:00–11:30 — Q4 roadmap working session`, or nil. Loaded
  through `organized_events` under the reading actor's policies.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Canonical.CalendarEvent

  @impl true
  def load(_query, _opts, _context) do
    now = DateTime.utc_now()

    next =
      CalendarEvent
      |> Ash.Query.filter(ends_at > ^now and status != :cancelled)
      |> Ash.Query.sort(starts_at: :asc)
      |> Ash.Query.limit(1)
      |> Ash.Query.ensure_selected([:starts_at, :ends_at, :status])
      |> Ash.Query.load([:title, :when])

    [organized_events: next]
  end

  @impl true
  def calculate(people, _opts, _context) do
    {:ok,
     Enum.map(people, fn person ->
       case person.organized_events do
         [event | _] -> "#{event.when} — #{event.title}"
         _none -> nil
       end
     end)}
  end
end
