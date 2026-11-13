defmodule AshEnterprise.Automation.Changes.CountAlert do
  @moduledoc """
  `Incident.join`: one more alert. Not atomic: the event log (`ash_events`) refuses atomic
  changes, and the only writer (`AshEnterprise.Automation.Incidents`) holds a lock on the
  incident's key while it reads and joins, so the count it read is the count it writes over.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(changeset, :alert_count, changeset.data.alert_count + 1)
  end
end
