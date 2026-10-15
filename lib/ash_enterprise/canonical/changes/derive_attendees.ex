defmodule AshEnterprise.Canonical.Changes.DeriveAttendees do
  @moduledoc """
  Derives `AshEnterprise.Canonical.EventAttendee` rows from a calendar event's
  upsert, in the same transaction (`AshEnterprise.Canonical.Derive.attendees/3`).

  Driven by the action's `attendees` argument: a list reconciles the event's
  attendees with it (`[]` clears them); an absent argument (nil) leaves them
  alone — a bare cancellation re-writes the event without knowing who was
  invited, and must not forget them.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Canonical.Derive

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :attendees) do
      attendees when is_list(attendees) ->
        Ash.Changeset.after_action(changeset, &derive(&1, &2, attendees))

      _absent ->
        changeset
    end
  end

  defp derive(changeset, event, attendees) do
    case Derive.attendees(event, attendees, changeset.tenant) do
      :ok -> {:ok, event}
      {:error, reason} -> {:error, derive_error(reason)}
    end
  end

  defp derive_error({resource, reason}) do
    Ash.Error.Changes.InvalidChanges.exception(
      message: "could not derive #{inspect(resource)} rows (#{reason})"
    )
  end
end
