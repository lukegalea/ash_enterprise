defmodule AshEnterprise.Agents.Calculations.RenderDraft do
  @moduledoc """
  Renders a morning brief's draft at read time from the calendar events its
  compose step selected (`event_ids`), through `MorningBrief.render/2`.

  The rendered text is never stored. Event titles and locations are sealed
  under their connection's erasure scope (ADR 0024); a stored copy of the
  rendered brief would be plaintext that no shred reaches, in the brief's row
  and in the audit event of the compose that wrote it. Rendering on read keeps
  each line under its own event's key, so after a shred the line reads
  `[shredded]` (`AshEnterprise.Erasure.Shredded` interpolates to that) while the
  times, which are structural, survive.

  The events are read without authorization, as the compose step selected
  them: whoever may read the brief may read the brief's text. One query per
  tenant for the whole batch of briefs.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Canonical.CalendarEvent

  @impl true
  def load(_query, _opts, _context), do: [:brief_date, :event_ids, :organization_id]

  @impl true
  def calculate(briefs, _opts, _context) do
    events_by_id =
      briefs
      |> Enum.reject(&is_nil(&1.event_ids))
      |> Enum.group_by(& &1.organization_id, & &1.event_ids)
      |> Enum.flat_map(fn {tenant, id_lists} -> read_events(tenant, Enum.concat(id_lists)) end)
      |> Map.new(&{&1.id, &1})

    {:ok, Enum.map(briefs, &render(&1, events_by_id))}
  end

  defp render(%{event_ids: nil}, _events_by_id), do: nil

  defp render(brief, events_by_id) do
    events =
      brief.event_ids
      |> Enum.flat_map(&List.wrap(Map.get(events_by_id, &1)))
      |> Enum.sort_by(& &1.starts_at, DateTime)

    MorningBrief.render(brief.brief_date, events)
  end

  defp read_events(_tenant, []), do: []

  defp read_events(tenant, ids) do
    ids = Enum.uniq(ids)

    CalendarEvent
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(tenant: tenant, authorize?: false)
  end
end
