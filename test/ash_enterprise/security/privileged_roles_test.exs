defmodule AshEnterprise.Security.PrivilegedRolesTest do
  @moduledoc """
  What makes a role privileged (`AshEnterprise.Security.Privilege.privileged?/3`,
  `AshEnterprise.Security.PrivilegedRoles`): what it grants, never its name. And the
  `security_alerts` pack's guards, which read the stamp and fall back to the role's name only
  for an event stamped before there was one. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: true

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1]

  require Ash.Query

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security.{Privilege, PrivilegedRoles, Role, RolePrivilege, UserRole}

  defp privileged?(resource, verb), do: Privilege.privileged?(name(resource), verb)

  defp name(resource) when is_binary(resource), do: resource
  defp name(resource), do: inspect(resource)

  defp role_id(tenant, name) do
    Role
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
    |> Map.fetch!(:id)
  end

  describe "a privilege is not privileged" do
    test "when it reads the authority resources" do
      for resource <- [Role, UserRole, RolePrivilege, AshEnterprise.Accounts.User],
          do: refute(privileged?(resource, :read), "read #{inspect(resource)}")
    end

    test "when it writes a resource that administers nothing" do
      refute privileged?(AshEnterprise.Bpmn.HumanTask, :write)
      refute privileged?(AshEnterprise.Mdm.MatchCandidate, :write)
      refute privileged?(AshEnterprise.Automation.Incident, :create)
    end

    test "when it is a secured column's read, on a resource that is not operator-only" do
      refute privileged?("AshEnterprise.Security.Role#name", :read)
    end

    test "when its resource is unknown" do
      refute privileged?("AshEnterprise.NoSuchResource", :write)
    end
  end

  describe "a privilege is privileged" do
    test "when its resource is operator-only, at any verb" do
      for resource <- Privilege.operator_only_resources(),
          verb <- [:read, :write],
          do: assert(privileged?(resource, verb), "#{verb} #{resource}")
    end

    test "when its verb reaches an action declared changes_authority" do
      # `User.assign_manager` and its siblings are updates: write on User reaches them.
      assert privileged?(AshEnterprise.Accounts.User, :write)
      # `Subscription.set_authority`, outside the Accounts and Security domains.
      assert privileged?(AshEnterprise.Bpmn.Subscription, :write)
    end

    test "when it writes a resource of the Accounts or Security domain" do
      for resource <- [Role, UserRole, RolePrivilege, AshEnterprise.Security.TeamRole],
          verb <- [:create, :write, :delete],
          do: assert(privileged?(resource, verb), "#{verb} #{inspect(resource)}")

      assert privileged?(AshEnterprise.Accounts.ApiKey, :create)
      assert privileged?(AshEnterprise.Accounts.TeamMembership, :create)
    end
  end

  describe "a seeded tenant's roles" do
    test "the starter roles are not privileged; the Administrator and the operator are" do
      admin = tenant!()
      opts = [authorize?: false, tenant: admin.tenant]

      for name <- [
            Seeder.data_steward_role(),
            Seeder.judgment_certifier_role(),
            Seeder.on_call_role()
          ] do
        refute PrivilegedRoles.privileged?(role_id(admin.tenant, name), opts), name
      end

      assert PrivilegedRoles.privileged?(admin.role.id, opts)

      %{role: operator} = Seeder.grant_platform_operator(colleague!(admin).user)
      assert PrivilegedRoles.privileged?(operator.id, opts)
    end

    test "a role is privileged in its own tenant only" do
      admin = tenant!()
      other = tenant!()

      assert PrivilegedRoles.privileged_role_ids([admin.role.id],
               tenant: other.tenant,
               authorize?: false
             ) ==
               MapSet.new()
    end

    test "a revoked grant no longer makes a role privileged" do
      admin = tenant!()
      opts = [authorize?: false, tenant: admin.tenant]

      role =
        Role
        |> Ash.Changeset.for_create(:create, %{name: "Directory Steward"},
          actor: SystemActor.seed(),
          tenant: admin.tenant
        )
        |> Ash.create!()

      privilege =
        Privilege
        |> Ash.Query.filter(resource_name == ^inspect(UserRole) and access_right == :create)
        |> Ash.read_one!(authorize?: false)

      grant =
        RolePrivilege
        |> Ash.Changeset.for_create(
          :create,
          %{role_id: role.id, privilege_id: privilege.id, depth: :global},
          actor: admin.actor,
          tenant: admin.tenant
        )
        |> Ash.create!()

      assert PrivilegedRoles.privileged?(role.id, opts)

      Ash.destroy!(grant, actor: admin.actor, tenant: admin.tenant)
      refute PrivilegedRoles.privileged?(role.id, opts)
    end
  end

  describe "the pack's guards" do
    @recipes "priv/packs/security_alerts/pack.json"
             |> File.read!()
             |> Jason.decode!()
             |> Map.fetch!("recipes")
             |> Map.new(&{&1["key"], &1["guard_feel"]})

    defp opens?(key, metadata) do
      {:ok, answer} = AshBpmn.Feel.evaluate(Map.fetch!(@recipes, key), %{"metadata" => metadata})
      answer == true
    end

    @single [
      "security_alerts.privileged_role_assigned",
      "security_alerts.privileged_role_assigned_to_team"
    ]
    @listed ["security_alerts.privileged_team_joined", "security_alerts.privileged_team_restored"]

    test "a stamped event that is not privileged opens nothing, whatever the role's name" do
      for key <- @single do
        refute opens?(key, %{"privileged" => false, "role_name" => "Administrator"}), key
        refute opens?(key, %{"privileged" => false}), key
      end

      for key <- @listed do
        refute opens?(key, %{
                 "privileged" => false,
                 "role_names" => ["Administrator"],
                 "privileged_role_names" => []
               }),
               key
      end

      refute opens?("security_alerts.held_role_made_privileged", %{"privileged" => false})
      refute opens?("security_alerts.held_role_made_privileged", %{})
    end

    test "an event stamped before there was a stamp opens nothing for another role's name" do
      for key <- @single, do: refute(opens?(key, %{"role_name" => "Report Reader"}), key)
      for key <- @listed, do: refute(opens?(key, %{"role_names" => ["Report Reader"]}), key)
      for key <- @single ++ @listed, do: refute(opens?(key, %{}), key)
    end

    test "a privileged stamp opens a review" do
      for key <- @single ++ @listed ++ ["security_alerts.held_role_made_privileged"],
          do:
            assert(opens?(key, %{"privileged" => true, "role_name" => "Directory Steward"}), key)
    end

    test "an event stamped before there was a stamp still opens by the role's name" do
      for key <- @single do
        assert opens?(key, %{"role_name" => "Administrator"}), key
        assert opens?(key, %{"role_name" => "Platform Operator"}), key
      end

      for key <- @listed,
          do: assert(opens?(key, %{"role_names" => ["Data Steward", "Administrator"]}), key)
    end
  end
end
