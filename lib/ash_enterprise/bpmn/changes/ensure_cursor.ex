defmodule AshEnterprise.Bpmn.Changes.EnsureCursor do
  @moduledoc """
  Establishes the tenant's trigger cursor after a write that makes the tenant interested in
  events (`AshEnterprise.Bpmn.Cursor.ensure!/1`): a subscription's lifecycle acts, and a
  process instance's start.

  Attached to every update of a subscription (`publish`, `retire`, `enable`, `disable`) rather
  than to `publish` alone, because ensuring is a no-op once the cursor exists: an
  enable/disable/retire can never roll it back to the present and silently skip everything
  in between. Only the first act on a tenant without a cursor stamps the mark.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      AshEnterprise.Bpmn.Cursor.ensure!(changeset.tenant)
      {:ok, record}
    end)
  end
end
