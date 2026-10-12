defmodule AshEnterprise.Canonical.Changes.DeriveParticipants do
  @moduledoc """
  Derives `AshEnterprise.Canonical.ConversationParticipant` rows from a
  conversation's upsert, in the same transaction
  (`AshEnterprise.Canonical.Derive.participants/3`).

  Driven by the `participants` input's `"person_ids"` — the people the
  projector resolved for the thread (the input is sealed into the row; the
  join keeps only the ids). A write without `participants` leaves the joins
  alone. It reads the input when the change runs, so it must be declared
  before `AshEnterprise.Erasure.Changes.SealUnderScope`, which seals the
  argument and removes it.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Canonical.Derive

  @impl true
  def change(changeset, _opts, _context) do
    case person_ids(changeset) do
      nil ->
        changeset

      person_ids ->
        Ash.Changeset.after_action(changeset, &derive(&1, &2, person_ids))
    end
  end

  # AshCloak takes the sealed attribute as an argument of the same name.
  defp person_ids(changeset) do
    participants =
      Ash.Changeset.get_argument(changeset, :participants) ||
        Ash.Changeset.get_attribute(changeset, :participants)

    case participants do
      %{} = map -> List.wrap(Map.get(map, "person_ids") || Map.get(map, :person_ids))
      _absent -> nil
    end
  end

  defp derive(changeset, conversation, person_ids) do
    case Derive.participants(conversation, person_ids, changeset.tenant) do
      :ok -> {:ok, conversation}
      {:error, {resource, reason}} -> {:error, derive_error(resource, reason)}
    end
  end

  defp derive_error(resource, reason) do
    Ash.Error.Changes.InvalidChanges.exception(
      message: "could not derive #{inspect(resource)} rows (#{reason})"
    )
  end
end
