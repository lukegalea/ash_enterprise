defmodule AshEnterprise.Process.Resolver do
  @moduledoc """
  Which definition of a process or a decision a tenant runs.

  This is **host policy**, not engine policy, which is why `AshBpmn.start_instance/2` takes a
  `:definition` and `AshBpmn.DefinitionLoader` is a replaceable seam: the engine has no
  business knowing that this application ships baselines centrally.

  ## The platform organization

  A baseline has to live somewhere, and it cannot live nowhere. `:base` plus `tenant?: true`
  raises by design, and the platform base resource makes `organization_id` `allow_nil? false`,
  so a NULL-tenant baseline row is impossible. Relaxing that would weaken the tenancy invariant
  for every resource in the application in order to serve one — refused.

  So the baseline lives in a **real organization row**, `unique_name: "platform"`, with no
  users, no roles and no sign-in. It is not a customer and must not look like one.

  ## Resolution

      resolve(:process, "access_request.grant", tenant)

  1. A `Binding` for `{kind, key}` in this tenant, `source: :tenant` → that target.
  2. A `Binding` with `source: :platform` → that *pinned* platform target. A tenant may
     deliberately hold at version 3 while the platform is on 5.
  3. No binding → the latest published definition for the key, in the platform organization.

  **Absence is the default**, which is what makes provisioning write nothing and reverting a
  customization a deletion.

  Two indexed reads worst case, and it is called **once per instance start** — never per
  advance, because an instance pins its definition for life.

  ## The one cross-tenant read

  Steps 2 and 3 read a row owned by the platform organization while acting for another tenant.
  That is the only legitimate cross-tenant read in the design, and it lives here in one named
  function rather than as `tenant: nil` sprinkled through callers. It is safe on three counts:
  the lookup is by primary key or by `(platform_tenant, key, status)`; the target is immutable
  once published; and a definition is not customer data.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Binding

  @platform_unique_name "platform"

  @doc """
  The platform organization's id, memoised.

  `:persistent_term` because it is read on every instance start and written once per boot; the
  global GC pause a write triggers is paid once.
  """
  @spec platform_tenant() :: Ash.UUID.t() | nil
  def platform_tenant do
    case :persistent_term.get({__MODULE__, :platform_tenant}, :miss) do
      :miss ->
        id = load_platform_tenant()
        if id, do: :persistent_term.put({__MODULE__, :platform_tenant}, id)
        id

      id ->
        id
    end
  end

  @doc "Forgets the memoised platform tenant. For tests and for after seeding."
  @spec forget_platform_tenant() :: :ok
  def forget_platform_tenant do
    :persistent_term.erase({__MODULE__, :platform_tenant})
    :ok
  end

  defp load_platform_tenant do
    Organization
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(unique_name == ^@platform_unique_name)
    |> Ash.read_one!(actor: SystemActor.process(), authorize?: false)
    |> case do
      nil -> nil
      organization -> organization.id
    end
  end

  @doc """
  Resolves the definition `tenant` should run for `key`.

  Returns `{:ok, definition}` or `{:error, reason}`. The caller pins whatever comes back; this
  is never consulted again for that instance.
  """
  @spec resolve(:process | :decision, String.t(), Ash.UUID.t()) ::
          {:ok, struct()} | {:error, term()}
  def resolve(kind, key, tenant) do
    case binding_for(kind, key, tenant) do
      %Binding{source: :tenant, target_id: id} ->
        load_definition(kind, id, tenant)

      %Binding{source: :platform, target_id: id} ->
        load_platform_definition(kind, id)

      nil ->
        latest_platform_definition(kind, key)
    end
  end

  @doc """
  Loads a definition belonging to the platform organization, by id.

  The named home of the cross-tenant read. Callers -- including the `ash_bpmn` definition
  loader -- go through this rather than passing a tenant of their own choosing.
  """
  @spec load_platform_definition(:process | :decision, Ash.UUID.t()) ::
          {:ok, struct()} | {:error, term()}
  def load_platform_definition(kind, id) do
    case platform_tenant() do
      nil -> {:error, :no_platform_organization}
      platform -> load_definition(kind, id, platform)
    end
  end

  defp latest_platform_definition(kind, key) do
    case platform_tenant() do
      nil ->
        {:error, {:no_platform_organization, key}}

      platform ->
        kind
        |> resource()
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(key == ^key and status == :published)
        |> Ash.Query.sort(version: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(actor: SystemActor.process(), tenant: platform)
        |> case do
          [definition] -> {:ok, definition}
          [] -> {:error, {:no_published_baseline, kind, key}}
        end
    end
  end

  defp load_definition(kind, id, tenant) do
    kind
    |> resource()
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      nil -> {:error, {:definition_not_found, kind, id}}
      definition -> {:ok, definition}
    end
  end

  defp binding_for(kind, key, tenant) do
    Binding
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(kind == ^kind and key == ^key)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end

  @doc """
  Starts a tenant's own copy of whatever it currently runs for `key`.

  The first half of customizing: create a **draft** in the tenant's own scope, seeded with the
  XML of the definition that tenant runs today. Editing and publishing it is the second half,
  and publishing is what writes the `Binding` -- so a fork that is never published changes
  nothing, which is the right shape for a draft.

  `forked_from_version` is recorded on the binding at publish time, not here, because a draft
  that is abandoned should leave no claim about lineage.

  ## Why it copies rather than references

  A tenant's version numbers are its own -- `AssignVersion` counts within the tenant -- so a
  fork of platform v5 is the tenant's v1. Without copying the XML, the tenant would be editing
  the platform's row, which is the thing this whole design exists to prevent.
  """
  @spec fork(:process | :decision, String.t(), Ash.UUID.t(), term()) ::
          {:ok, struct()} | {:error, term()}
  def fork(kind, key, tenant, actor \\ nil) do
    with {:ok, source} <- resolve(kind, key, tenant) do
      opts = [actor: actor || SystemActor.process(), tenant: tenant]

      existing_draft =
        kind
        |> resource()
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(key == ^key and status == :draft)
        |> Ash.read_one!(opts)

      case existing_draft do
        # A key has at most one draft, enforced by a partial unique index. Returning the
        # existing one makes forking idempotent, which a seed needs and a double-click wants.
        %{} = draft ->
          {:ok, draft}

        nil ->
          {:ok,
           resource(kind).create!(
             %{key: key, name: source.name, xml: source.xml},
             opts
           )}
      end
    end
  end

  @doc """
  What each customized key has diverged from.

  Returns `[%{kind:, key:, forked_from_version:, platform_version:, behind_by:}]`.

  Deliberately **not** a diff and **not** a merge. The two documents have diverged and
  reconciling them is the round-tripping problem in another costume: telling a tenant it is two
  versions behind, and showing both side by side, is honest; merging them is not.
  """
  @spec drift(Ash.UUID.t()) :: [map()]
  def drift(tenant) do
    Binding
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> Enum.map(fn binding ->
      platform_version = latest_platform_version(binding.kind, binding.key)

      %{
        kind: binding.kind,
        key: binding.key,
        source: binding.source,
        bound_version: binding.bound_version,
        forked_from_version: binding.forked_from_version,
        platform_version: platform_version,
        behind_by: behind_by(binding.forked_from_version, platform_version)
      }
    end)
  end

  defp behind_by(nil, _platform), do: nil
  defp behind_by(_forked, nil), do: nil
  defp behind_by(forked, platform) when platform > forked, do: platform - forked
  defp behind_by(_forked, _platform), do: 0

  defp latest_platform_version(kind, key) do
    case latest_platform_definition(kind, key) do
      {:ok, %{version: version}} -> version
      {:error, _} -> nil
    end
  end

  defp resource(:process), do: AshEnterprise.Bpmn.Definition
  defp resource(:decision), do: AshEnterprise.Decisions.Definition
end
