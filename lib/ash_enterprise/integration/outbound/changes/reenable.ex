defmodule AshEnterprise.Integration.Outbound.Changes.Reenable do
  @moduledoc """
  Turns an endpoint back on and clears its run of dead-lettered deliveries. The cursor is
  kept, so what was written while it was off is sent, except after
  `"cursor_behind_retention"`: those events are in the archive now, so the cursor restarts
  at the tenant's high-water mark and the gap is left to the audit export.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Audit.EventSource

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, :active)
    |> Ash.Changeset.force_change_attribute(:status_reason, nil)
    |> Ash.Changeset.force_change_attribute(:consecutive_dead, 0)
    |> restamp(changeset.data)
  end

  defp restamp(changeset, %{status_reason: "cursor_behind_retention", organization_id: tenant}) do
    Ash.Changeset.force_change_attribute(
      changeset,
      :cursor_sequence,
      EventSource.latest_sequence(tenant)
    )
  end

  defp restamp(changeset, _endpoint), do: changeset
end
