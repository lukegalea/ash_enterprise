defmodule AshEnterprise.Canonical.Calculations.NextEvent do
  @moduledoc """
  The next not-cancelled event a person organizes, for a directory row:
  `Tue 13 Oct · 10:00–11:30 — Q4 roadmap working session`, or nil.

  `organized_events` is loaded in `calculate/3` **as the reader**, under
  their policies: a relationship named in `load/3` would be loaded as a
  calculation dependency, which Ash does without authorization (see
  `AshEnterprise.Platform.Calculations.RelatedField`). An event the reader
  may not read is not their next event.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Canonical.CalendarEvent
  alias AshEnterprise.Platform.Calculations.RelatedField

  # Only the person's own key: the events are loaded as the reader below.
  @impl true
  def load(_query, _opts, _context), do: [:id]

  @impl true
  def calculate(people, _opts, context) do
    now = DateTime.utc_now()

    next =
      CalendarEvent
      |> Ash.Query.filter(ends_at > ^now and status != :cancelled)
      |> Ash.Query.sort(starts_at: :asc)
      |> Ash.Query.limit(1)
      |> Ash.Query.ensure_selected([:starts_at, :ends_at, :status])
      |> Ash.Query.load([:title, :when])

    with {:ok, loaded} <- RelatedField.load_related(people, :organized_events, next, context) do
      {:ok,
       Enum.map(loaded, fn person ->
         case person.organized_events do
           [event | _] -> "#{event.when} — #{event.title}"
           _none -> nil
         end
       end)}
    end
  end
end
