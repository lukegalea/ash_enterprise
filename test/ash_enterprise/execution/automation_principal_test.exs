defmodule AshEnterprise.Execution.AutomationPrincipalTest do
  @moduledoc """
  The automation principal (ADR 0043) and the execution identity's request side, in the
  sandbox: its context comes only from its role rows, it runs on the intersection with
  the person it acts for, it never reaches a person-only path, and a person may ask for
  it only for an agent they hold the start grant for.

  What happens at the claim, after a commit, is `reauth_test.exs` (durability tier).
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures
  import AshEnterprise.Test.Execution.Authority

  require Ash.Query

  alias AshAgent.Invocation.NoPrincipal
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Identity
  alias AshEnterprise.Platform.{AutomationPrincipal, Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.ActorContext.Grant
  alias AshEnterprise.Test.Execution.ClinicNote

  @record "AshEnterprise.Test.Execution.ClinicNote.record"
  @agent "note-tidier"

  defp key, do: "test:#{System.unique_integer([:positive])}"

  defp grant(fields), do: struct(Grant, fields)
  defp units(ids), do: MapSet.new(ids)

  describe "the intersection" do
    @tenant Ash.UUID.generate()
    @note {"Note", :write}
    @u1 Ash.UUID.generate()
    @u2 Ash.UUID.generate()

    defp person(grants, shared \\ %{}),
      do: %ActorContext{
        user_id: Ash.UUID.generate(),
        organization_id: @tenant,
        team_ids: [Ash.UUID.generate()],
        task_ids: [Ash.UUID.generate()],
        task_instance_ids: [Ash.UUID.generate()],
        grants: grants,
        shared: shared
      }

    defp automation(grants),
      do: %ActorContext{automation: :evidence_admitter, organization_id: @tenant, grants: grants}

    test "reaches only what both reach" do
      cases = [
        # {person's grant, principal's grant, expected}
        {%{global?: true}, %{basic?: true}, %{basic?: true}},
        {%{basic?: true}, %{global?: true}, %{basic?: true}},
        {%{global?: true}, %{global?: true}, %{global?: true}},
        {%{business_unit_ids: units([@u1, @u2])}, %{business_unit_ids: units([@u2])},
         %{business_unit_ids: units([@u2])}},
        # Reached by different routes: left out rather than guessed.
        {%{basic?: true}, %{business_unit_ids: units([@u1])}, nil},
        {%{basic?: true, business_unit_ids: units([@u1])}, %{basic?: true}, %{basic?: true}}
      ]

      for {mine, its, expected} <- cases do
        both =
          ActorContext.intersect(
            person(%{@note => grant(mine)}),
            automation(%{@note => grant(its)})
          )

        assert Map.get(both.grants, @note) == if(expected, do: grant(expected))
      end
    end

    test "a grant only one side holds is no grant" do
      read = {"Note", :read}
      both = ActorContext.intersect(person(%{read => grant(%{global?: true})}), automation(%{}))
      assert both.grants == %{}

      both = ActorContext.intersect(person(%{}), automation(%{read => grant(%{global?: true})}))
      assert both.grants == %{}
    end

    test "keeps the person's identity and shares only where the principal reaches everything" do
      record = Ash.UUID.generate()
      shared = %{@note => MapSet.new([record]), {"Other", :write} => MapSet.new([record])}
      me = person(%{}, shared)

      both =
        ActorContext.intersect(
          me,
          automation(%{
            @note => grant(%{global?: true}),
            {"Other", :write} => grant(%{basic?: true})
          })
        )

      assert {both.user_id, both.team_ids, both.organization_id, both.automation} ==
               {me.user_id, me.team_ids, @tenant, :evidence_admitter}

      assert both.shared == %{@note => MapSet.new([record])}
      # Never a task candidate, never a system context, no reporting chain.
      assert {both.task_ids, both.task_instance_ids, both.system?, both.hierarchy} ==
               {[], [], false, nil}
    end

    test "contexts of different tenants, or a system context, intersect to nothing" do
      everything = %{@note => grant(%{global?: true})}
      elsewhere = %{automation(everything) | organization_id: Ash.UUID.generate()}

      for {mine, its} <- [
            {person(everything), elsewhere},
            {%{person(everything) | system?: true}, automation(everything)}
          ] do
        both = ActorContext.intersect(mine, its)
        assert {both.grants, both.user_id} == {%{}, nil}
      end
    end
  end

  describe "the principal's own context" do
    setup do
      admin = tenant!()
      %{admin: admin}
    end

    test "comes from its role rows in that tenant, and is never a system context", %{admin: admin} do
      assert ActorContext.build_automation(:evidence_admitter, admin.tenant).grants == %{}

      automation_role!(admin, :evidence_admitter, [{ClinicNote, :write, :global}])
      context = ActorContext.build_automation(:evidence_admitter, admin.tenant)

      assert ActorContext.grant(context, ClinicNote, :write).global?
      refute context.system?
      assert is_nil(context.user_id)

      # Another clinic's rows are not this one's.
      other = tenant!()
      assert ActorContext.build_automation(:evidence_admitter, other.tenant).grants == %{}
    end

    test "a principal with no context attached can do nothing", %{admin: admin} do
      automation_role!(admin, :evidence_admitter, [{ClinicNote, :read, :global}])
      bare = AutomationPrincipal.evidence_admitter()

      note!(admin, "Restock the gloves")

      # A read narrows rather than raises: to nothing.
      assert Ash.read!(ClinicNote, actor: bare, tenant: admin.tenant) == []
      refute Ash.can?({ClinicNote, :record}, bare, tenant: admin.tenant)
      assert ActorContext.for_actor(bare) == %ActorContext{automation: :evidence_admitter}
    end

    test "giving a principal a role is a person's act", %{admin: admin} do
      assert Ash.can?({Security.AutomationRole, :assign}, admin.actor, tenant: admin.tenant)
      assert Ash.can?({Security.AgentStartGrant, :grant}, admin.actor, tenant: admin.tenant)

      for system <- [SystemActor.seed(), SystemActor.oban()] do
        refute Ash.can?({Security.AutomationRole, :assign}, system, tenant: admin.tenant)
        refute Ash.can?({Security.AgentStartGrant, :grant}, system, tenant: admin.tenant)
      end
    end

    test "nor can a principal acting for an administrator give one", %{admin: admin} do
      # The principal holds the same role administration grants as its person.
      automation_role!(admin, :evidence_admitter, [
        {Security.AutomationRole, :create, :global},
        {Security.AgentStartGrant, :create, :global}
      ])

      acting =
        AutomationPrincipal.acting(
          AutomationPrincipal.evidence_admitter(),
          admin.user.id,
          @agent,
          ActorContext.intersect(
            ActorContext.build(admin.user, tenant: admin.tenant),
            ActorContext.build_automation(:evidence_admitter, admin.tenant)
          )
        )

      assert ActorContext.grant(ActorContext.for_actor(acting), Security.AutomationRole, :create).global?
      refute Ash.can?({Security.AutomationRole, :assign}, acting, tenant: admin.tenant)
      refute Ash.can?({Security.AgentStartGrant, :grant}, acting, tenant: admin.tenant)
    end

    test "a new tenant's Administrator may assign roles to principals and start grants" do
      seeded = Seeder.seed_tenant(unique_name: "auto-#{System.unique_integer([:positive])}")

      for resource <- [Security.AutomationRole, Security.AgentStartGrant] do
        name = inspect(resource)

        granted =
          Security.RolePrivilege
          |> Ash.Query.filter(role_id == ^seeded.role.id and privilege.resource_name == ^name)
          |> Ash.Query.load(:privilege)
          |> Ash.read!(actor: SystemActor.seed(), tenant: seeded.organization.id)
          |> Enum.map(& &1.privilege.access_right)

        assert :create in granted
        assert :delete in granted
      end
    end
  end

  describe "asking for automation work" do
    setup do
      admin = tenant!()
      nurse = member!(admin, "Nurse #{System.unique_integer([:positive])}", [])
      %{admin: admin, nurse: nurse}
    end

    test "needs the agent's start grant", %{admin: admin, nurse: nurse} do
      asking = starting(nurse, :evidence_admitter, @agent)

      assert {:error, %Ash.Error.Forbidden{errors: [%NoPrincipal{reason: :no_start_grant}]}} =
               Execution.invoke(@record, %{"title" => "x"}, %{key: key()},
                 actor: asking.actor,
                 tenant: asking.tenant
               )

      # A grant for another agent is not this one's.
      start_grant!(admin, nurse, "another-agent")

      assert {:error, %Ash.Error.Forbidden{}} =
               Execution.invoke(@record, %{"title" => "x"}, %{key: key()},
                 actor: asking.actor,
                 tenant: asking.tenant
               )
    end

    test "with the grant, names the principal and the person it acts for; the person owns the row",
         %{admin: admin, nurse: nurse} do
      start_grant!(admin, nurse, @agent)
      asking = starting(nurse, :evidence_admitter, @agent)

      row =
        Execution.invoke!(@record, %{"title" => "Tidy the shift notes"}, %{key: key()},
          actor: asking.actor,
          tenant: asking.tenant
        )

      assert row.executing_principal == %{
               type: :automation,
               id: "evidence_admitter",
               on_behalf_of: nurse.user.id,
               agent: @agent
             }

      assert row.delegation == %{
               "sub" => "person:#{nurse.user.id}",
               "act" => %{"sub" => "automation:evidence_admitter", "client_id" => @agent}
             }

      assert row.owner_id == nurse.user.id
    end

    test "a start grant held through a team counts", %{admin: admin, nurse: nurse} do
      team = team_with!(admin, nurse)

      Security.AgentStartGrant.grant!(
        %{agent_key: @agent, principal_id: team.id, principal_type: :team},
        actor: admin.actor,
        tenant: admin.tenant
      )

      assert {:ok, %{type: :automation}} =
               Identity.principal_for(
                 AutomationPrincipal.start(nurse.actor, :evidence_admitter, @agent),
                 %{tenant: nurse.tenant}
               )
    end

    test "an unknown principal, a system actor, `ai` and a bare principal name no principal",
         %{admin: admin, nurse: nurse} do
      start_grant!(admin, nurse, @agent)
      context = %{tenant: nurse.tenant}

      assert {:error, :unknown_automation_principal} =
               Identity.principal_for(
                 AutomationPrincipal.start(nurse.actor, :nobody, @agent),
                 context
               )

      for actor <- [SystemActor.ai(), SystemActor.oban(), AutomationPrincipal.evidence_admitter()] do
        assert {:error, :not_a_person} = Identity.principal_for(actor, context)
      end
    end

    test "a stored principal with no person is refused at the claim" do
      assert {:error, :requesterless} =
               Identity.actor_for(%{
                 executing_principal: %{type: :automation, id: "evidence_admitter", agent: @agent},
                 organization_id: Ash.UUID.generate()
               })
    end
  end

  defp team_with!(admin, member) do
    team =
      AshEnterprise.Accounts.Team
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Ward #{System.unique_integer([:positive])}",
          owning_business_unit_id: admin.user.owning_business_unit_id
        },
        actor: SystemActor.seed(),
        tenant: admin.tenant
      )
      |> Ash.create!()

    AshEnterprise.Accounts.TeamMembership
    |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: member.user.id},
      actor: SystemActor.seed(),
      tenant: admin.tenant
    )
    |> Ash.create!()

    team
  end
end
