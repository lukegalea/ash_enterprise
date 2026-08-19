defmodule AshEnterprise.Process.DefinitionLoader do
  @moduledoc """
  Loads the definition an instance is pinned to, wherever it lives.

  The seam `ash_bpmn` provides for exactly this application's shape. The engine's default
  reads a definition in the *instance's* tenant, which is right whenever a tenant runs its own
  processes and wrong the moment it runs a platform baseline: the instance is the tenant's and
  the definition is the platform organization's.

  Getting this wrong is quiet rather than loud, which is why the seam exists at all. The token
  claims, the loader finds nothing, and the process sits at its start node with no error
  anywhere — which is precisely how it presented before this module existed.

  ## It is a lookup, never a resolution

  The definition returned must be **the one the instance pinned**. Returning "the latest
  version of that key" instead would silently migrate a running instance onto a definition it
  was never verified against — the one failure the whole versioning design exists to prevent.
  Choosing *which* definition a new instance runs happens once, in
  `AshEnterprise.Process.Resolver`, at start time.
  """

  @behaviour AshBpmn.DefinitionLoader

  require Ash.Query

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Resolver

  @impl true
  def load(resource, definition_id, instance, scope) do
    # The instance's own tenant first: a tenant that has customized this process owns the
    # definition, and that is the common case once anyone has diverged.
    case read(resource, definition_id, Map.get(scope, :tenant)) do
      {:ok, definition} ->
        {:ok, definition}

      :not_found ->
        # Then the platform organization, which is where a baseline lives. The one legitimate
        # cross-tenant read in the design, and it goes through the named function rather than
        # a `tenant:` of this module's choosing.
        platform_fallback(resource, definition_id, instance)
    end
  end

  defp platform_fallback(resource, definition_id, instance) do
    case read(resource, definition_id, Resolver.platform_tenant()) do
      {:ok, definition} ->
        {:ok, definition}

      :not_found ->
        {:error,
         {:definition_not_found, definition_id,
          "not in the instance's tenant #{inspect(Map.get(instance, :organization_id))} " <>
            "nor in the platform organization"}}
    end
  end

  defp read(_resource, _definition_id, nil), do: :not_found

  defp read(resource, definition_id, tenant) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^definition_id)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      nil -> :not_found
      definition -> {:ok, definition}
    end
  rescue
    _ -> :not_found
  end
end
