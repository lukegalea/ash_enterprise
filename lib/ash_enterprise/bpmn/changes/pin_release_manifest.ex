defmodule AshEnterprise.Bpmn.Changes.PinReleaseManifest do
  @moduledoc """
  On an instance's create: records the active release manifest that pins its process as
  `release_manifest_id`, so the run keeps what that release pinned for its whole life
  (`AshEnterprise.Process.DecisionResolver`). An instance of a process no active manifest
  names is not pinned, and decides as it always did.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Manifests
  alias AshEnterprise.Process.Resolver

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &pin/1)
  end

  defp pin(%{tenant: tenant} = changeset) when is_binary(tenant) do
    with id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :definition_id),
         {:ok, definition} <- Resolver.definition(:process, id, tenant),
         {:ok, %{id: manifest_id}} <- Manifests.covering(:process, definition.key, tenant) do
      Ash.Changeset.force_change_attribute(changeset, :release_manifest_id, manifest_id)
    else
      _not_covered -> changeset
    end
  end

  defp pin(changeset), do: changeset
end
