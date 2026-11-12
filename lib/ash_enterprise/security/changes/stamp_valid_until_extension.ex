defmodule AshEnterprise.Security.Changes.StampValidUntilExtension do
  @moduledoc """
  Records on `UserRole :set_valid_until`'s audit event whether the change extended the
  grant: `metadata.valid_until_extended`, `true` or `false`.

  An extension is a grant lasting longer than it did, which is a grant of access for the
  added time, so the `soc2_cc6_3` pack reviews it as it reviews an assignment. A recipe's
  guard reads only the event, and the event's data holds the new `valid_until`, not the old
  one, so "longer than before" has to be decided here, where both are known, and written
  down. Extended means:

    * an end set, then cleared (the grant becomes open-ended), or
    * an end moved later, including moving an end already past to a time after it.

  Clearing an end that was not set, setting an earlier end, or setting the same end is not
  an extension.

  Decided in a `before_action`, on the value the write will store, and merged into the
  event's metadata beside what `AshEnterprise.Platform.Changes.StampCorrelation` put there.
  """

  use Ash.Resource.Change

  @key "valid_until_extended"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      before = Map.get(changeset.data, :valid_until)
      after_change = Ash.Changeset.get_attribute(changeset, :valid_until)

      metadata =
        changeset.context
        |> Map.get(:ash_events_metadata, %{})
        |> Map.put(@key, extended?(before, after_change))

      Ash.Changeset.set_context(changeset, %{ash_events_metadata: metadata})
    end)
  end

  @doc "Whether moving a grant's end from `before` to `after_change` makes it last longer."
  @spec extended?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def extended?(nil, _after_change), do: false
  def extended?(%DateTime{}, nil), do: true

  def extended?(%DateTime{} = before, %DateTime{} = after_change),
    do: DateTime.compare(after_change, before) == :gt
end
