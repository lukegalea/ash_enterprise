defmodule AshEnterprise.Automation.Changes.TrackIncident do
  @moduledoc """
  After an `AshEnterprise.Automation.Occurrence` is recorded, in the same transaction: an
  alert occurrence opens, joins or closes an incident (`AshEnterprise.Automation.Incidents`).
  Any other occurrence passes through untouched. A failure fails the recording, so an alert
  is never kept without what it did to its incident.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Automation.Incidents

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, occurrence ->
      case Incidents.track(occurrence) do
        {:ok, _what} -> {:ok, occurrence}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
