defmodule AshEnterprise.Agents.Changes.ComposeDraft do
  @moduledoc """
  Composes the morning brief: selects the day's canonical calendar events, in
  the composing actor's tenant, and records their ids. The draft text itself
  is rendered on read (`AshEnterprise.Agents.Calculations.RenderDraft`). Runs inside the
  `compose_brief` action, so the policy engine and the audit entry see exactly
  what a person triggering the compose would see — the process gets no
  privileged path to the data.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Canonical.CalendarEvent

  @impl true
  def change(changeset, _opts, _context) do
    # The selection is made here, inside the action, because the events must
    # be read at execution time (the process may compose long after the
    # subject was created). `force_` because this runs after validation by
    # construction — the compose is the action's work, not caller input.
    #
    # Only the event ids are stored, never the rendered text: titles and
    # locations are sealed under their connection's erasure scope, and a
    # rendered copy would be plaintext in this row and in the compose's audit
    # event that no shred reaches (ADR 0024). `draft_text` renders on read.
    Ash.Changeset.before_action(changeset, fn changeset ->
      date = Ash.Changeset.get_attribute(changeset, :brief_date)
      owner_id = Ash.Changeset.get_attribute(changeset, :owner_id)

      Ash.Changeset.force_change_attribute(
        changeset,
        :event_ids,
        Enum.map(events_for(date, owner_id, changeset.tenant), & &1.id)
      )
    end)
  end

  # The brief's day is the operator's local day (`LocalTime`), cut in the
  # display zone, so an evening meeting is in the brief for the day it happens
  # on rather than the next UTC day's.
  #
  # The brief's owner's events only. The read is unauthorized (the process
  # actor composes), so the owner filter is what keeps one person's calendar
  # out of a colleague's brief once briefs are composed for every calendar
  # owner in a tenant.
  defp events_for(date, owner_id, tenant) do
    {day_start, day_end} = AshEnterprise.Platform.LocalTime.days(date, 1)

    CalendarEvent
    |> Ash.Query.filter(
      owner_id == ^owner_id and starts_at >= ^day_start and starts_at < ^day_end
    )
    |> Ash.Query.sort(:starts_at)
    |> Ash.read!(tenant: tenant, authorize?: false)
  end
end
