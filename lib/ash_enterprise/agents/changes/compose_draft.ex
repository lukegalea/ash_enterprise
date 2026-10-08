defmodule AshEnterprise.Agents.Changes.ComposeDraft do
  @moduledoc """
  Composes the morning brief's deterministic draft from the day's canonical
  calendar events, in the composing actor's tenant. Runs inside the
  `compose_brief` action, so the policy engine and the audit entry see exactly
  what a person triggering the compose would see — the process gets no
  privileged path to the data.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Canonical.CalendarEvent

  @impl true
  def change(changeset, _opts, _context) do
    # The draft is computed here, inside the action, because the events must
    # be read at execution time (the process may compose long after the
    # subject was created). `force_` because this runs after validation by
    # construction — the compose is the action's work, not caller input.
    Ash.Changeset.before_action(changeset, fn changeset ->
      date = Ash.Changeset.get_attribute(changeset, :brief_date)

      Ash.Changeset.force_change_attribute(
        changeset,
        :draft_text,
        MorningBrief.render(date, events_for(date, changeset.tenant))
      )
    end)
  end

  defp events_for(date, tenant) do
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = DateTime.add(day_start, 1, :day)

    CalendarEvent
    |> Ash.Query.filter(starts_at >= ^day_start and starts_at < ^day_end)
    |> Ash.Query.sort(:starts_at)
    |> Ash.read!(tenant: tenant, authorize?: false)
  end
end
