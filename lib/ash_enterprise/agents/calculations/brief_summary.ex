defmodule AshEnterprise.Agents.Calculations.BriefSummary do
  @moduledoc """
  A morning brief in one line, for a row: `6 events · 08:30–17:30 · 1 cancelled`
  (the operator's wall clock), `No events scheduled`, or `Not composed yet`.

  Structural only — counts and times, never a title — read from the events the
  compose step selected, the same way `RenderDraft` reads them: whoever may
  read the brief may read its outline.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Canonical.CalendarEvent
  alias AshEnterprise.Platform.LocalTime

  @impl true
  def load(_query, _opts, _context), do: [:event_ids, :organization_id]

  @impl true
  def calculate(briefs, _opts, _context) do
    events_by_id =
      briefs
      |> Enum.reject(&is_nil(&1.event_ids))
      |> Enum.group_by(& &1.organization_id, & &1.event_ids)
      |> Enum.flat_map(fn {tenant, ids} -> read_events(tenant, Enum.concat(ids)) end)
      |> Map.new(&{&1.id, &1})

    {:ok, Enum.map(briefs, &summary(&1, events_by_id))}
  end

  defp summary(%{event_ids: nil}, _events), do: "Not composed yet"
  defp summary(%{event_ids: []}, _events), do: "No events scheduled"

  defp summary(brief, events_by_id) do
    events =
      brief.event_ids
      |> Enum.flat_map(&List.wrap(Map.get(events_by_id, &1)))
      |> Enum.sort_by(& &1.starts_at, DateTime)

    case events do
      [] ->
        "No events scheduled"

      [first | _] ->
        last = Enum.max_by(events, & &1.ends_at, DateTime)
        count = length(events)
        cancelled = Enum.count(events, &(&1.status == :cancelled))
        noun = if count == 1, do: "event", else: "events"
        span = "#{LocalTime.time(first.starts_at)}–#{LocalTime.time(last.ends_at)}"
        tail = if cancelled > 0, do: " · #{cancelled} cancelled", else: ""
        "#{count} #{noun} · #{span}#{tail}"
    end
  end

  defp read_events(_tenant, []), do: []

  defp read_events(tenant, ids) do
    ids = Enum.uniq(ids)

    CalendarEvent
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :starts_at, :ends_at, :status])
    |> Ash.read!(tenant: tenant, authorize?: false)
  end
end
