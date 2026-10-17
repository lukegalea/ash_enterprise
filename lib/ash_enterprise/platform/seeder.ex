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

  Returns the number of privileges written — only the missing or changed
  ones, so a re-run against an up-to-date catalogue writes nothing. Safe to
  re-run; runs at every boot (`AshEnterprise.Platform.PrivilegeSync`).
  """
  def seed_privileges do
    written = write_privileges()

    # Every deploy runs this, so it is also where a deployment provisioned
    # before operator-only privileges existed loses the Administrator grants
    # on them (see `revoke_operator_privileges_from_administrators/0`).
    revoke_operator_privileges_from_administrators()

    # ...and where a grant made before a resource became owner-only is
    # narrowed to the one depth it may now hold.
    narrow_owner_only_grants()

    written
  end

  # Writes only what is missing or has changed (a resource added, or its
  # legal depths moved), so a re-run against an up-to-date catalogue is one
  # read — cheap enough to run at every boot (`AshEnterprise.Platform.PrivilegeSync`).
  defp write_privileges do
    actor = SystemActor.seed()

    existing =
      Security.Privilege
      |> Ash.read!(actor: actor)
      |> Map.new(&{{&1.resource_name, &1.access_right}, privilege_fields(&1)})

    for resource <- platform_resources(),
        verb <- AshEnterprise.Security.AccessRight.verbs(),
        fields = desired_privilege(resource, verb),
        Map.get(existing, {fields.resource_name, verb}) != fields do
      Security.Privilege
      |> Ash.Changeset.for_create(:create, fields, actor: actor)
      |> Ash.create!()
    end
    |> length()
  end

  defp desired_privilege(resource, verb) do
    legal = Security.Privilege.legal_depths_for(resource, ownership_of(resource))

    %{
      resource_name: inspect(resource),
      access_right: verb,
      name: privilege_name(resource, verb),
      can_be_basic: :basic in legal,
      can_be_local: :local in legal,
      can_be_deep: :deep in legal,
      can_be_global: :global in legal
    }
  end

  defp privilege_fields(privilege) do
    Map.take(privilege, [
      :resource_name,
      :access_right,
      :name,
      :can_be_basic,
      :can_be_local,
      :can_be_deep,
      :can_be_global
    ])
  end

  @doc """
  Provisions a tenant: organization, root business unit, default team, an
  administrator role granting everything at `:global` (bar the operator-only
  privileges, and `:basic` on the owner-only ones), the starter Data Steward
  role (`ensure_data_steward_role/2`), and an admin user.

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

    # `force_change_attribute` rather than an accepted argument: both ids are
    # `writable? false`, and deliberately so -- an id a client can choose is an
    # id a client can collide. The one caller that legitimately needs to pick is
    # the legacy estate (`seed_legacy_estate/1`), whose ids are baked into a view
    # definition that is checked in and therefore cannot depend on what a seed
    # generated. Creating still goes through the real action, so every change
    # runs -- notably `MaintainBusinessUnitPath`, which `Ash.Seed.seed!/2` would
    # have skipped, leaving a root unit with no materialized path and grant
    # depth quietly reaching nothing.
    organization =
      Accounts.Organization
      |> Ash.Changeset.for_create(:create, %{name: name, unique_name: unique_name}, actor: actor)
      |> force_id(opts[:organization_id])
      |> Ash.create!()

    tenant = organization.id

    root =
      Accounts.BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: name}, actor: actor, tenant: tenant)
      |> force_id(opts[:business_unit_id])
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
    _steward = ensure_data_steward_role(tenant, dry_run?: false)
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

  @platform_unique_name "platform"

  @operator_role "Platform Operator"

  @doc """
  Removes every operator-only privilege
  (`AshEnterprise.Security.Privilege.operator_only?/1`) from every tenant's
  Administrator role.

  Before those privileges were reserved, `seed_tenant/1` and
  `regrant_administrator_privileges/1` granted them to every Administrator at
  `:global` — and a `:global` grant on an untenanted resource reaches every
  tenant's rows: any tenant's Administrator could read every other tenant's
  raw provider landings, decrypted, and shred any tenant's erasure scope.
  Idempotent; returns the number of grants removed. Grant the operator their
  own role with `grant_platform_operator/1`.
  """
  @spec revoke_operator_privileges_from_administrators() :: non_neg_integer()
  def revoke_operator_privileges_from_administrators do
    actor = SystemActor.seed()

    operator_privilege_ids =
      Security.Privilege
      |> Ash.Query.filter(resource_name in ^Security.Privilege.operator_only_resources())
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.id)

    if operator_privilege_ids == [] do
      0
    else
      # Across tenants: grants are tenant data, and the seed actor reads them
      # without a tenant (platform multitenancy is `global?`).
      Security.RolePrivilege
      |> Ash.Query.filter(
        privilege_id in ^operator_privilege_ids and role.name == "Administrator"
      )
      |> Ash.read!(actor: actor)
      |> Enum.map(fn grant ->
        Ash.destroy!(grant, actor: actor, tenant: grant.organization_id)
      end)
      |> length()
    end
  end

  @doc """
  Narrows every role grant on an owner-only resource
  (`AshEnterprise.Security.Privilege.owner_only?/1`) to `:basic`, in every
  tenant.

  Owner-only resources hold one person's own mail and Slack. A grant wider
  than `:basic` on them — an Administrator's `:global` from before they were
  owner-only — reaches every user's rows in the tenant. Run by
  `seed_privileges/0` on every deploy, after the catalogue is rewritten.
  Idempotent; returns the number of grants narrowed.
  """
  @spec narrow_owner_only_grants() :: non_neg_integer()
  def narrow_owner_only_grants do
    actor = SystemActor.seed()

    owner_only_ids =
      Security.Privilege
      |> Ash.Query.filter(resource_name in ^Security.Privilege.owner_only_resources())
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.id)

    if owner_only_ids == [] do
      0
    else
      # Across tenants, as revoke_operator_privileges_from_administrators/0.
      Security.RolePrivilege
      |> Ash.Query.filter(privilege_id in ^owner_only_ids and depth != :basic)
      |> Ash.read!(actor: actor)
      |> Enum.map(fn grant ->
        grant
        |> Ash.Changeset.for_update(:update, %{depth: :basic},
          actor: actor,
          tenant: grant.organization_id
        )
        |> Ash.update!()
      end)
      |> length()
    end
  end

  @doc """
  Makes `user` the platform operator: a `#{@operator_role}` role in their
  tenant holding every operator-only privilege at `:global` (read raw
  landings, open and shred erasure scopes), assigned to them.

  The only path to those privileges: a tenant role cannot be granted them by
  anyone but a system actor (`OperatorPrivilegeNeedsSystemActor`), and this
  runs as the `seed` system actor. Behind
  `mix ash_enterprise.platform.grant_operator --email <operator>`. Idempotent.

  The grant reaches every tenant (the resources are untenanted). Anyone
  holding `write` on user roles in the operator's tenant can assign the role
  to someone else there, so keep that tenant's administrators to platform
  staff.
  """
  @spec grant_platform_operator(Accounts.User.t()) :: %{
          role: struct(),
          granted: non_neg_integer()
        }
  def grant_platform_operator(user) do
    actor = SystemActor.seed()
    context = Security.ActorContext.build(user)
    tenant = context.organization_id
    business_unit_id = context.business_unit_id

    if is_nil(tenant) or is_nil(business_unit_id) do
      raise ArgumentError, "the platform operator must belong to a business unit in a tenant"
    end

    opts = [actor: actor, tenant: tenant]

    role =
      Security.Role
      |> Ash.Query.filter(
        name == ^@operator_role and owning_business_unit_id == ^business_unit_id
      )
      |> Ash.read_one!(opts) ||
        Security.Role
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: @operator_role,
            description:
              "Platform staff: raw provider landings and erasure scopes, across every tenant. " <>
                "Granted by mix ash_enterprise.platform.grant_operator.",
            owning_business_unit_id: business_unit_id
          },
          opts
        )
        |> Ash.create!()

    granted =
      Security.Privilege
      |> Ash.Query.filter(resource_name in ^Security.Privilege.operator_only_resources())
      |> Ash.read!(actor: actor)
      |> Enum.filter(& &1.can_be_global)
      |> Enum.map(fn privilege ->
        Security.RolePrivilege
        |> Ash.Changeset.for_create(
          :create,
          %{role_id: role.id, privilege_id: privilege.id, depth: :global},
          opts
        )
        |> Ash.create!()
      end)
      |> length()

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: business_unit_id},
      opts
    )
    |> Ash.create!()

    %{role: role, granted: granted}
  end

  @doc """
  Grants every existing role the privileges it is missing, in one tenant.

  ## Why this is needed at all

  `seed_tenant/1` grants the Administrator role every globally-grantable privilege **at
  provisioning time**, except the operator-only ones
  (`AshEnterprise.Security.Privilege.operator_only?/1`), which no tenant role is
  auto-granted. A resource added afterwards has privileges nobody holds, so the role
  that is supposed to reach everything silently stops reaching the new thing — and the symptom
  is a forbidden write on a resource an administrator can see in the admin UI, which reads as a
  bug in the resource rather than as a stale grant.

  There was no idempotent way to fix that: re-running the seed refuses, because provisioning a
  tenant twice is a mistake rather than a no-op. This is that path.

  Only the Administrator role, and only globally-grantable privileges: widening a *customer's*
  roles automatically would be the platform quietly changing who can do what, which is exactly
  what `docs/manifesto/03-authorization-is-data.md` exists to prevent. Any other role is the
  tenant's to manage.

  Returns the number of grants added.
  """
  @spec regrant_administrator_privileges(Ash.UUID.t()) :: non_neg_integer()
  def regrant_administrator_privileges(tenant) do
    actor = SystemActor.seed()
    opts = [actor: actor, tenant: tenant]

    role =
      Security.Role
      |> Ash.Query.filter(name == "Administrator")
      |> Ash.read_one!(opts)

    if role do
      held =
        Security.RolePrivilege
        |> Ash.Query.filter(role_id == ^role.id)
        |> Ash.read!(opts)
        |> MapSet.new(& &1.privilege_id)

      Security.Privilege
      |> Ash.read!(actor: actor)
      |> Enum.reject(
        &(Security.Privilege.operator_only?(&1.resource_name) or MapSet.member?(held, &1.id) or
            is_nil(Security.Privilege.widest_depth(&1)))
      )
      |> Enum.map(fn privilege ->
        Security.RolePrivilege
        |> Ash.Changeset.for_create(
          :create,
          %{
            role_id: role.id,
            privilege_id: privilege.id,
            depth: Security.Privilege.widest_depth(privilege)
          },
          opts
        )
        |> Ash.create!()
      end)
      |> length()
    else
      0
    end
  end

  @data_steward "Data Steward"

  # What a steward needs and nothing more: the queue and its verdicts
  # (read and write on match candidates — `:confirm`, `:reject` and
  # `:escalate` are updates), the rows the steward surfaces show beside them
  # (staged rows, import batches, the mappings a batch pinned, the source
  # identities a golden's lineage lists), the goldens they own (Person is
  # owner-only, so `:basic`), the human verdict each decision records as the
  # steward, and the MDM egress departure (ADR 0054). Every verdict needs
  # read on the candidate's golden (`GoldenReadable`), and `:basic` reaches
  # only the steward's own: an import's goldens belong to whoever ran it, so
  # a steward decides those once they are shared with them (ADR 0054,
  # addendum "every verdict needs the golden"). No grant on tasks: a
  # steward reads and acts on steward-decision tasks through candidacy
  # (`AshEnterprise.Security.Checks.TaskCandidacy`), as a role candidate.
  @data_steward_grants [
    {AshEnterprise.Mdm.MatchCandidate, :read},
    {AshEnterprise.Mdm.MatchCandidate, :write},
    {AshEnterprise.Mdm.StagedRecord, :read},
    {AshEnterprise.Mdm.ImportBatch, :read},
    {AshEnterprise.Mdm.Mapping, :read},
    {AshEnterprise.Mdm.SourceIdentity, :read},
    {AshEnterprise.Canonical.Person, :read},
    {AshEnterprise.SystemOne.HumanVerdict, :create},
    {AshEnterprise.Mdm.Egress, :read}
  ]

  @doc "The starter steward role's name."
  @spec data_steward_role() :: String.t()
  def data_steward_role, do: @data_steward

  @doc "The `{resource, verb}` grants the Data Steward role carries, each at its widest depth."
  @spec data_steward_grants() :: [{module(), atom()}]
  def data_steward_grants, do: @data_steward_grants

  @doc """
  Makes sure `tenant` has the starter **Data Steward** role, holding the
  steward-queue grants and the MDM egress grant (`data_steward_grants/0`),
  each at the widest depth its privilege allows (`:basic` on Person, which is
  owner-only).

  Idempotent and additive: creates the role in the tenant's root business
  unit if it is missing and adds the grants it lacks; it never removes a grant
  or touches another role, and assigns the role to nobody. A tenant that
  narrowed the role on purpose gets the missing grants back, so this is a
  deliberate act — `seed_tenant/1` runs it for a new tenant, and existing
  tenants receive it through `regrant_data_steward/1`
  (`mix ash_enterprise.platform.grant_data_steward`), not at boot.

  **Dry run by default** (`dry_run?: true`): reports what it would do and
  writes nothing. Pass `dry_run?: false` to apply.

  Returns `%{tenant: id, role: :created | :exists | :would_create, added: [{resource, verb, depth}], dry_run?: boolean}`.
  """
  @spec ensure_data_steward_role(Ash.UUID.t(), keyword()) :: map()
  def ensure_data_steward_role(tenant, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run?, true)
    actor = SystemActor.seed()
    ash = [actor: actor, tenant: tenant]

    role =
      Security.Role
      |> Ash.Query.filter(name == ^@data_steward)
      |> Ash.read_one!(ash)

    held =
      if role do
        Security.RolePrivilege
        |> Ash.Query.filter(role_id == ^role.id)
        |> Ash.read!(ash)
        |> MapSet.new(& &1.privilege_id)
      else
        MapSet.new()
      end

    missing =
      for {resource, verb} <- @data_steward_grants,
          privilege = privilege!(resource, verb, actor),
          not MapSet.member?(held, privilege.id),
          do: {privilege, Security.Privilege.widest_depth(privilege)}

    added = Enum.map(missing, fn {p, depth} -> {p.resource_name, p.access_right, depth} end)

    if dry_run? do
      %{
        tenant: tenant,
        role: if(role, do: :exists, else: :would_create),
        added: added,
        dry_run?: true
      }
    else
      {status, role} =
        if role, do: {:exists, role}, else: {:created, create_data_steward!(tenant, actor)}

      for {privilege, depth} <- missing do
        Security.RolePrivilege
        |> Ash.Changeset.for_create(
          :create,
          %{role_id: role.id, privilege_id: privilege.id, depth: depth},
          ash
        )
        |> Ash.create!()
      end

      %{tenant: tenant, role: status, added: added, dry_run?: false}
    end
  end

  @doc """
  `ensure_data_steward_role/2` across tenants: every real tenant (not the
  platform organization) by default, or the one named by `tenant:` (its id or
  `unique_name`). Dry run unless `dry_run?: false`. Returns one report per
  tenant, in the shape `ensure_data_steward_role/2` documents.
  """
  @spec regrant_data_steward(keyword()) :: [map()]
  def regrant_data_steward(opts \\ []) do
    opts
    |> Keyword.get(:tenant)
    |> steward_tenants()
    |> Enum.map(&ensure_data_steward_role(&1.id, dry_run?: Keyword.get(opts, :dry_run?, true)))
  end

  defp steward_tenants(nil) do
    platform = @platform_unique_name

    Accounts.Organization
    |> Ash.Query.filter(unique_name != ^platform or is_nil(unique_name))
    |> Ash.Query.sort(:unique_name)
    |> Ash.read!(actor: SystemActor.seed())
  end

  defp steward_tenants(name_or_id) do
    # Only the canonical 36-character form is an id: `Ecto.UUID.cast/1` also
    # takes any 16-byte string as a raw UUID, and "e2e-steward-1605" is one.
    query =
      if byte_size(name_or_id) == 36 and match?({:ok, _}, Ecto.UUID.cast(name_or_id)),
        do: Ash.Query.filter(Accounts.Organization, id == ^name_or_id),
        else: Ash.Query.filter(Accounts.Organization, unique_name == ^name_or_id)

    case Ash.read!(query, actor: SystemActor.seed()) do
      [] -> raise ArgumentError, "no tenant #{inspect(name_or_id)}"
      tenants -> tenants
    end
  end

  defp privilege!(resource, verb, actor) do
    name = inspect(resource)

    Security.Privilege
    |> Ash.Query.filter(resource_name == ^name and access_right == ^verb)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil ->
        raise "no #{verb} privilege for #{name}: run Seeder.seed_privileges/0 first"

      privilege ->
        privilege
    end
  end

  defp create_data_steward!(tenant, actor) do
    root =
      Accounts.BusinessUnit
      |> Ash.Query.filter(is_nil(parent_business_unit_id))
      |> Ash.read_one!(actor: actor, tenant: tenant)

    Security.Role
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: @data_steward,
        description:
          "Decides MDM match candidates (confirm, reject, unsure) and runs the MDM egress. " <>
            "Seeded by the platform.",
        owning_business_unit_id: root.id
      },
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()
  end

  @doc """
  The platform organization's `unique_name`.

  Exposed so callers can *exclude* it. It is infrastructure rather than a
  tenant — nobody signs into it, and it exists to hold centrally published
  baselines — so anything enumerating tenants for a human, or picking one to
  act on, has to be able to tell it apart from a real one by something better
  than its display name.
  """
  @spec platform_unique_name() :: String.t()
  def platform_unique_name, do: @platform_unique_name

  @doc """
  Seeds the platform organization: where baseline processes and decisions are published.

  A baseline has to live in a tenant, because the platform base resource makes
  `organization_id` `allow_nil? false` and relaxing that to serve one resource would weaken
  the tenancy invariant for every resource in the application.

  So it is a real `Organization` row -- and deliberately an empty one. **No users, no roles,
  no sign-in.** It is not a customer and must not be mistaken for one: nothing should ever
  authenticate into it, and a tenant listing shown to a human should exclude it.

  Idempotent, like `seed_legacy_estate/1` and unlike `seed_tenant/1`, because it runs on every
  deploy that publishes a baseline.
  """
  @spec seed_platform_organization() :: Accounts.Organization.t()
  def seed_platform_organization do
    actor = SystemActor.seed()

    existing =
      Accounts.Organization
      |> Ash.Query.filter(unique_name == ^@platform_unique_name)
      |> Ash.read_one!(authorize?: false)

    organization =
      existing ||
        Accounts.Organization
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Platform (baselines)", unique_name: @platform_unique_name},
          actor: actor
        )
        |> Ash.create!()

    # The resolver memoises this id, and seeding is exactly when it can have been memoised as
    # absent.
    AshEnterprise.Process.Resolver.forget_platform_tenant()

    organization
  end

  @doc """
  Provisions the tenant the legacy estate belongs to, at the fixed ids
  `AshEnterprise.Legacy.User`'s mapping names.

  A second tenant alongside `seed_tenant/1`'s, on purpose. Plan §4.2 makes the
  point that a tenant with one member proves nothing about isolation: the
  evidence that multitenancy survived being *added* to data that never had it is
  that the legacy rows are invisible from the greenfield organization. Two
  tenants is the smallest arrangement in which that is a claim rather than a
  hope.

  Idempotent: returns `:already_seeded` if the organization exists, so this can
  run on every deploy.
  """
  @spec seed_legacy_estate(keyword()) :: map() | :already_seeded
  def seed_legacy_estate(opts \\ []) do
    organization_id = AshEnterprise.Legacy.Estate.organization_id()

    existing =
      Accounts.Organization
      |> Ash.Query.filter(id == ^organization_id)
      |> Ash.read_one!(authorize?: false)

    if existing do
      :already_seeded
    else
      seed_tenant(
        name: opts[:name] || "Legacy Estate",
        unique_name: opts[:unique_name] || "legacy",
        email: opts[:email] || "admin@legacy.example",
        password: opts[:password] || "password1234",
        organization_id: organization_id,
        business_unit_id: AshEnterprise.Legacy.Estate.business_unit_id()
      )
    end
  end

  defp force_id(changeset, nil), do: changeset
  defp force_id(changeset, id), do: Ash.Changeset.force_change_attribute(changeset, :id, id)

  # An administrator role granting every privilege at the widest depth it
  # supports -- :global, except :basic on the owner-only resources -- so the
  # grant is never one of the "reaches nothing while looking like a
  # restriction" combinations that DepthLegalForPrivilege rejects.
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

    grantable =
      Enum.filter(
        privileges,
        &(not Security.Privilege.operator_only?(&1.resource_name) and
            not is_nil(Security.Privilege.widest_depth(&1)))
      )

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
        %{
          role_id: role.id,
          privilege_id: privilege.id,
          depth: Security.Privilege.widest_depth(privilege)
        },
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

    # `:provision_with_password`, not `:register_with_password`: registering
    # sends a confirmation email built against the running endpoint, which the
    # seed task does not start (iron law #23), and nobody receives mail at a
    # seeded address. Provisioning creates the user already confirmed.
    user = existing || provision_user!(email, password)

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
  Creates a user who is already confirmed and can sign in with `password`,
  without sending a confirmation email or needing the endpoint.

  Through `AshEnterprise.Accounts.User`'s `:provision_with_password`, as the
  `seed` system actor, which is the only kind of actor that action accepts.
  Shared with `AshEnterprise.Platform.DemoData`.
  """
  @spec provision_user!(String.t(), String.t()) :: Accounts.User.t()
  def provision_user!(email, password) do
    Accounts.User
    |> Ash.Changeset.for_create(
      :provision_with_password,
      %{email: email, password: password},
      actor: SystemActor.seed()
    )
    |> Ash.create!()
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
  # Resources the privilege catalogue governs even though they are not
  # platform resources. The audit event log was the precedent: append-only
  # machinery without ownership columns, whose access still must be a role
  # grant. The compliance plane adds two of the same shape — the compliance
  # event log the KYC reviews append to, and the finding projection the
  # compliance door (`AshEnterprise.Surfaces.Doors`) is gated on. Their
  # ownership resolves to `:none`, so only `:global` grants are legal — an
  # organization-level grant on an engine table would be a fiction.
  defp additionally_governed do
    [
      AshEnterprise.Audit.EventLog,
      AshEnterprise.Compliance.EventLog,
      AshCompliance.Resources.Finding
    ]
  end

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
