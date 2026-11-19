defmodule AshEnterprise.Integration.Outbound.Changes.StampCursor do
  @moduledoc """
  Starts a new endpoint's cursor at its tenant's current high-water mark in the audit log,
  so an endpoint is sent only what happens after it was registered and never replays
  history. Runs inside the create's transaction.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      tenant = Ash.Changeset.get_attribute(changeset, :organization_id) || changeset.tenant

      Ash.Changeset.force_change_attribute(
        changeset,
        :cursor_sequence,
        AshEnterprise.Audit.EventSource.latest_sequence(tenant)
      )
    end)
  end
end
