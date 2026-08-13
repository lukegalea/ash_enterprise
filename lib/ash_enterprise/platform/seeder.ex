defmodule AshEnterprise.Platform.Seeder do
  @moduledoc """
  Bootstraps a tenant into a usable state: an organization, a root business unit,
  the privilege catalogue, a set of starter roles, and an administrator.

  ## The chicken-and-egg problem

  Provisioning a tenant is the one operation that cannot be authorized normally.
  The first administrator has no roles, because roles live inside the tenant that
  does not exist yet; and the privilege catalogue describes the *software*, so
  nothing in the data model can grant permission to create it.

  So this runs as `AshEnterprise.Platform.SystemActor.seed()` — a named non-human
  actor that bypasses the role model. Every write is still attributed, so the
  audit log distinguishes "the seeder created this" from "we do not know who
  created this". See `AshEnterprise.Platform.SystemActor`.

  ## The privilege catalogue is derived, not authored

  `seed_privileges/0` walks the configured domains and emits one privilege per
  `(resource, verb)`, with the legal depths determined by each resource's
  ownership model. Hand-maintaining that list would let it drift from what the
  application can actually do — and the dangerous direction of drift is a missing
  privilege, because it silently makes some access ungrantable.

  Idempotent throughout: every create upserts, so this is safe to run on every
  deploy.

      mix ash_enterprise.seed
  """

  require Ash.Query

  alias AshEnterprise.Accounts
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security

  @doc """
  Seeds the privilege catalogue from the configured domains.

  Returns the number of privileges written. Safe to re-run.
  """
  def seed_privileges do
    for resource <- platform_resources(),
        verb <- AshEnterprise.Security.AccessRight.verbs() do
      ownership = ownership_of(resource)
      legal = Security.Privilege.legal_depths(ownership)

      Security.Privilege
      |> Ash.Changeset.for_create(
        :create,
        %{
          resource_name: inspect(resource),
          access_right: verb,
          name: privilege_name(resource, verb),
          can_be_basic: :basic in legal,
          can_be_local: :local in legal,
          can_be_deep: :deep in legal,
          can_be_global: :global in legal
        },
        actor: SystemActor.seed()
      )
      |> Ash.create!()
    end
    |> length()
  end

  @doc """
  Provisions a tenant: organization, root business unit, default team, an
  administrator role granting everything at `:global`, and an admin user.

  Returns `%{organization: _, business_unit: _, role: _, user: _}`.
  """
  def seed_tenant(opts \\ []) do
    name = opts[:name] || "Example Corp"
    unique_name = opts[:unique_name] || "example"
    email = opts[:email] || "admin@example.com"
    password = opts[:password] || "password1234"

    actor = SystemActor.seed()

    # The privilege catalogue must exist before the Administrator role is built,
    # or `seed_admin_role/3` finds nothing to grant and produces a role with ZERO
    # privileges -- which is worse than an error, because it looks configured in
    # the admin UI and grants nothing at all. Idempotent, so calling it here
    # costs nothing when it has already run.
    seed_privileges()

    organization =
      Accounts.Organization
      |> Ash.Changeset.for_create(:create, %{name: name, unique_name: unique_name}, actor: actor)
      |> Ash.create!()

    tenant = organization.id

    root =
      Accounts.BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: name}, actor: actor, tenant: tenant)
      |> Ash.create!()

    _default_team =
      Accounts.Team
      |> Ash.Changeset.for_create(
        :create_default_for_business_unit,
        %{name: "#{name} (All Users)", owning_business_unit_id: root.id},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()

    role = seed_admin_role(root, tenant, actor)
    user = seed_admin_user(email, password, root, organization)

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: root.id},
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()

    %{organization: organization, business_unit: root, role: role, user: user}
  end

  # An administrator role granting every privilege at :global -- but only at
  # depths each privilege actually supports, so the grant is never one of the
  # "reaches nothing while looking like a restriction" combinations that
  # DepthLegalForPrivilege rejects.
  defp seed_admin_role(root, tenant, actor) do
    role =
      Security.Role
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Administrator",
          description: "Full access within the tenant. Seeded by the platform.",
          owning_business_unit_id: root.id
        },
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()

    privileges =
      Security.Privilege
      |> Ash.Query.new()
      |> Ash.read!(actor: actor)

    grantable = Enum.filter(privileges, & &1.can_be_global)

    if grantable == [] do
      raise """
      Cannot seed the Administrator role: the privilege catalogue is empty.

      A role with no grants reaches nothing while appearing in the admin UI as a
      configured role, so this fails loudly rather than producing one.

      Run `mix ash_enterprise.seed` (which seeds the catalogue first), or call
      AshEnterprise.Platform.Seeder.seed_privileges/0 before seed_tenant/1.
      """
    end

    for privilege <- grantable do
      Security.RolePrivilege
      |> Ash.Changeset.for_create(
        :create,
        %{role_id: role.id, privilege_id: privilege.id, depth: :global},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()
    end

    role
  end

  defp seed_admin_user(email, password, root, organization) do
    existing =
      Accounts.User
      |> Ash.Query.filter(email == ^email)
      |> Ash.read_one!(authorize?: false)

    user =
      existing ||
        Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{email: email, password: password, password_confirmation: password},
          authorize?: false
        )
        |> Ash.create!()

    user
    |> Ash.Changeset.for_update(
      :assign_to_business_unit,
      %{owning_business_unit_id: root.id},
      authorize?: false
    )
    |> Ash.update!()
    |> Map.put(:organization_id, organization.id)
  end

  @doc """
  Every resource across the configured domains that participates in the platform
  (i.e. carries the `platform` DSL section).

  Resources without it -- Token, the audit log -- are authentication and
  infrastructure rather than things a role grants access to.
  """
  def platform_resources do
    :ash_enterprise
    |> Application.get_env(:ash_domains, [])
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&platform_resource?/1)
    |> Enum.concat(additionally_governed())
    |> Enum.uniq()
    |> Enum.sort_by(&inspect/1)
  end

  # Resources that are NOT platform resources -- they carry no ownership,
  # tenancy or lifecycle columns -- but whose access still has to be grantable.
  #
  # The audit log is the case in point: it has no owner and no business unit, so
  # only :global grants are meaningful on it, but reading it must still require
  # a deliberate grant rather than being available to anyone who can reach the
  # admin UI. Without a privilege row there would be nothing to grant, and the
  # policy on the resource would deny everyone including administrators.
  defp additionally_governed, do: [AshEnterprise.Audit.EventLog]

  defp platform_resource?(resource) do
    AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource)
  end

  defp ownership_of(resource) do
    if platform_resource?(resource) do
      Spark.Dsl.Extension.get_opt(resource, [:platform], :ownership, :user_owned)
    else
      # No ownership columns at all, so only Organization-level access is
      # meaningful -- the same treatment Dataverse gives its own unowned tables.
      :none
    end
  end

  defp privilege_name(resource, verb) do
    entity = resource |> Module.split() |> List.last()
    "prv#{verb |> to_string() |> Macro.camelize()}#{entity}"
  end
end
