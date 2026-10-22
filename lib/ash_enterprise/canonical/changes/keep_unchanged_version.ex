defmodule AshEnterprise.Canonical.Changes.KeepUnchangedVersion do
  @moduledoc """
  On a temporal upsert, writes nothing when the event already says what
  the write says: the version valid at the write's instant stays the
  current one, and the action returns it.

  `CalendarEvent` is temporal (ADR 0049), and its upsert splits the version
  valid at the write's instant on every match (in ash_postgres), even
  when no value changed. A projector re-writes an event whenever its
  provider reports it, and Google reports an event for changes this model
  does not project (a description, someone's answer to the invitation),
  and every replay and full resync re-writes all of them. Without this,
  each would add an identical version, the history would fill with
  versions that record nothing, and walking it
  (`AshEnterprise.Platform.TemporalHistory`) would cost a read for each.

  The comparison is on the values the projection writes: the sealed
  `title` and `location` in the clear (they arrive as arguments, which
  `AshEnterprise.Erasure.Changes.SealUnderScope` seals afterwards, so this
  change is declared on the action, ahead of the resource-wide changes),
  and `starts_at`, `ends_at`, `status`, `organizer_id`, `erasure_scope_id`
  and `external_uid`. Anything else that differs writes a new version.

  The action's other hooks still run against the kept version: the
  attendee joins are reconciled (`DeriveAttendees`), and the business
  events derive nothing, because nothing about the event changed.

  ## Temporal safety (ADR 0049 invariant 4)

  It reads no clock. The current version is read through Ash, in the
  write's tenant, as of the write's own instant when it has one, inside the
  write's transaction (a `before_action` hook), so it is the version the
  upsert would otherwise split.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Canonical.CalendarEvent

  @sealed [:title, :location]
  @compared [:starts_at, :ends_at, :status, :organizer_id, :erasure_scope_id, :external_uid]

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    # The plaintext is only here now: SealUnderScope removes the arguments.
    sealed = Map.new(@sealed, &{&1, sealed_input(changeset, &1)})
    Ash.Changeset.before_action(changeset, &keep_if_unchanged(&1, sealed))
  end

  defp sealed_input(changeset, field) do
    case Ash.Changeset.fetch_argument(changeset, field) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp keep_if_unchanged(changeset, sealed) do
    with system when is_binary(system) <- Ash.Changeset.get_attribute(changeset, :external_system),
         id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :external_id),
         {:ok, %CalendarEvent{} = current} <- current(changeset, system, id),
         true <- unchanged?(current, changeset, sealed) do
      Ash.Changeset.set_result(changeset, {:ok, current})
    else
      _write -> changeset
    end
  end

  defp current(changeset, system, id) do
    CalendarEvent.by_external(
      system,
      id,
      [tenant: changeset.tenant, authorize?: false] ++ as_of(changeset.as_of)
    )
  end

  defp as_of(%DateTime{} = at), do: [as_of: at]
  defp as_of(_now), do: []

  defp unchanged?(current, changeset, sealed) do
    Enum.all?(@sealed, &(Map.get(current, &1) == sealed[&1])) and
      Enum.all?(
        @compared,
        &same?(Map.get(current, &1), Ash.Changeset.get_attribute(changeset, &1))
      )
  end

  defp same?(%DateTime{} = left, %DateTime{} = right), do: DateTime.compare(left, right) == :eq
  defp same?(left, right), do: left == right
end
