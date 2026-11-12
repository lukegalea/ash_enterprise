defmodule AshEnterprise.Execution.Authority do
  @moduledoc """
  What this host answers about its people for approval postures
  (`AshAgent.Approval.Posture`): the posture in force for a tenant, everyone
  who holds or has ever held a role, its administrator role, and its platform
  operators. Named `authority` in the `invocation` section of
  `AshEnterprise.Execution.Invocation` and in the `approval_posture` section
  of `AshEnterprise.Accounts.Organization`; the package calls it and never
  reads this host's people, roles or tenants itself.

  Each answer is a fact about people, not an authority check — it is called
  with the tenant and no actor, and reads without authorization:

    * **The posture** is the tenant's `Organization` row, which carries it
      through `AshAgent.Approval.PostureFragment`; a tenant this deployment
      does not know is `:standard`.
    * **The holders of a role** (`:administrator` is the role named
      "Administrator", `AshEnterprise.Execution.Approval.role_name/1`) are everyone who holds it in the tenant or has
      ever held it, directly or through a team: assignments in force or
      revoked, memberships current or ended, people active or not, wherever
      they are now. Revoking a role, taking someone off a team and
      deactivating them are each one person's act, so a holder removed that
      way still counts, and four eyes stays closed as it would without the
      posture. The `:history` reads include archived rows.
    * **The administrator role** is the tenant's Administrator role, the one
      `AshEnterprise.Security.Validations.AdministratorKeepsItsName` pins to
      its name.
    * **A platform operator** is a person whose role grants them `write` at
      `:global` on one of the operator-only resources
      (`AshEnterprise.Security.Privilege.operator_only?/1`) — the grant
      `mix ash_enterprise.platform.grant_operator` makes. The platform, not
      the tenant, vouches for them.

  Who may call the actions that use these facts is the host's policies, not
  this module.
  """

  @behaviour AshAgent.Approval.Authority

  alias AshEnterprise.Accounts.{Organization, TeamMembership}
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Security.{ActorContext, Privilege, Role, TeamRole, UserRole}

  @administrator :administrator

  @impl true
  def posture(tenant) do
    case Ash.get(Organization, tenant, authorize?: false, not_found_error?: false) do
      {:ok, %Organization{approval_posture: posture, approval_posture_ends_at: ends_at}} ->
        {posture || :standard, ends_at}

      _unknown_tenant ->
        {:standard, nil}
    end
  end

  @impl true
  def holders(nil, _role), do: []

  def holders(tenant, role) do
    opts = [authorize?: false, tenant: tenant]
    role_ids = ids(Role, [name: Approval.role_name(role)], :id, opts)
    team_ids = ids(TeamRole, [role_id: [in: role_ids]], :team_id, opts)

    Enum.uniq(
      ids(UserRole, [role_id: [in: role_ids]], :user_id, opts) ++
        ids(TeamMembership, [team_id: [in: team_ids]], :user_id, opts)
    )
  end

  @impl true
  def administrator_role, do: @administrator

  @impl true
  def operator?(actor) do
    context = ActorContext.for_actor(actor)

    not context.system? and context.user_id != nil and is_nil(context.automation) and
      active?(actor) and
      Enum.any?(Privilege.operator_only_resources(), &global_write?(context, &1))
  end

  defp active?(actor), do: Map.get(actor, :lifecycle_status) == :active

  defp global_write?(context, resource),
    do: match?(%ActorContext.Grant{global?: true}, ActorContext.grant(context, resource, :write))

  defp ids(resource, filter, field, opts) do
    resource
    |> Ash.Query.for_read(:history, %{}, opts)
    |> Ash.Query.filter_input(filter)
    |> Ash.Query.select([field])
    |> Ash.read!()
    |> Enum.map(&Map.fetch!(&1, field))
  end
end
