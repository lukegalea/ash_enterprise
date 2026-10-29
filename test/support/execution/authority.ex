defmodule AshEnterprise.Test.Execution.Authority do
  @moduledoc """
  Grant rows for the execution-identity tests (ADR 0043): roles on the test clinic note,
  automation principals' roles, agent start grants, and the ways a test takes authority
  away between a request and its claim.

  The clinic note lives in a domain the privilege seeder never sees, so its privileges
  are written here, idempotently.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, User}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.ClinicNote

  @retitle "AshEnterprise.Test.Execution.ClinicNote.retitle"

  @doc "The update target: retitling a note needs a role granting `write` on it."
  def retitle_target, do: @retitle

  @doc "Writes the clinic note's `read` and `write` privileges, if they are missing."
  def note_privileges! do
    for verb <- [:read, :write] do
      Security.Privilege.create!(
        %{
          resource_name: inspect(ClinicNote),
          access_right: verb,
          name: "prv#{verb}ClinicNote",
          can_be_basic: true,
          can_be_local: true,
          can_be_deep: true,
          can_be_global: true
        },
        actor: SystemActor.seed()
      )
    end

    :ok
  end

  @doc "A member of `admin`'s clinic whose role reads and retitles notes at `depth`."
  def note_keeper!(admin, depth) do
    note_privileges!()

    DailyFixtures.member!(admin, "Keeper #{System.unique_integer([:positive])}", [
      {ClinicNote, :read, depth},
      {ClinicNote, :write, depth}
    ])
  end

  @doc "A note `member` records as themselves (self-service), so they own it."
  def note!(member, title) do
    Ash.create!(ClinicNote, %{title: title},
      action: :record,
      actor: member.actor,
      tenant: member.tenant
    )
  end

  @doc "The note `id`'s title as committed, read past every policy."
  def title(tenant, id),
    do: Ash.get!(ClinicNote, id, tenant: tenant, authorize?: false).title

  @doc """
  A role in `admin`'s clinic granting `grants` (`{resource, verb, depth}`), assigned to
  the automation principal `name` by `admin`, a person. Returns the assignment.
  """
  def automation_role!(admin, name, grants) do
    note_privileges!()
    role = role!(admin, grants)

    Security.AutomationRole.assign!(
      %{
        principal: name,
        role_id: role.id,
        scoping_business_unit_id: admin.user.owning_business_unit_id
      },
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  @doc "`admin` lets `member` start the agent `agent`."
  def start_grant!(admin, member, agent) do
    Security.AgentStartGrant.grant!(
      %{agent_key: agent, principal_id: member.user.id, principal_type: :user},
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  @doc "Removes every role `member` holds directly, as an administrator revoking them."
  def revoke_roles!(member) do
    id = member.user.id

    Security.UserRole
    |> Ash.Query.filter(user_id == ^id)
    |> Ash.read!(authorize?: false, tenant: member.tenant)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false, tenant: member.tenant))
  end

  @doc "Moves `member` into a business unit of `other`'s clinic, as a transfer would."
  def move_to!(member, other) do
    unit = Ash.get!(BusinessUnit, other.user.owning_business_unit_id, authorize?: false)

    member.user
    |> Ash.Changeset.for_update(:assign_to_business_unit, %{owning_business_unit_id: unit.id},
      authorize?: false
    )
    |> Ash.update!()

    :ok
  end

  @doc "`member`'s actor, marked as asking for `agent` to run as the principal `name`."
  def starting(member, name, agent),
    do: %{
      member
      | actor: AshEnterprise.Platform.AutomationPrincipal.start(member.actor, name, agent)
    }

  @doc "Reloads `member`'s user."
  def reload(member), do: %{member | user: Ash.get!(User, member.user.id, authorize?: false)}

  defp role!(admin, grants) do
    role =
      Security.Role
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Automation #{System.unique_integer([:positive])}",
          owning_business_unit_id: admin.user.owning_business_unit_id
        },
        actor: SystemActor.seed(),
        tenant: admin.tenant
      )
      |> Ash.create!()

    for {resource, verb, depth} <- grants do
      name = inspect(resource)

      privilege =
        Security.Privilege
        |> Ash.Query.filter(resource_name == ^name and access_right == ^verb)
        |> Ash.read_one!(authorize?: false)

      Security.RolePrivilege
      |> Ash.Changeset.for_create(
        :create,
        %{role_id: role.id, privilege_id: privilege.id, depth: depth},
        actor: SystemActor.seed(),
        tenant: admin.tenant
      )
      |> Ash.create!()
    end

    role
  end
end
