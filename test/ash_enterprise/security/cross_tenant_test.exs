defmodule AshEnterprise.Security.CrossTenantTest do
  @moduledoc """
  An actor's authority stays in the tenant its context was built for
  (`AshEnterprise.Security.Checks.ContextTenant`).

  A context's grants carry no tenant of their own. Before the check, a person whose
  context was built for tenant B, holding a `:global` role there, asked about tenant A
  (`Ash.can?({Resource, :create}, actor, tenant: a)`) was told yes: the grant union
  read `global?: true` off the context and never looked at the call's tenant. The
  web takes both from the same session, but every caller that names a tenant
  itself — a job, a tool call, a script — could put the two apart.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Conformance.Widget
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.Privilege
  alias AshEnterprise.Security.Role
  alias AshEnterprise.Security.RolePrivilege
  alias AshEnterprise.Security.UserRole

  setup do
    a = tenant("A")
    b = tenant("B")

    privileges =
      Map.new([:read, :write, :create, :delete], fn verb -> {verb, privilege(verb)} end)

    for t <- [a, b], verb <- [:read, :write, :create, :delete] do
      grant_global(t, privileges[verb])
    end

    %{
      a: a,
      b: b,
      widget_a: widget("A's widget", a),
      widget_b: widget("B's widget", b)
    }
  end

  describe "a person's context built for one tenant" do
    test "is refused in another tenant, though it holds :global grants in its own", ctx do
      actor = actor_for(ctx.b)

      refute Ash.can?({Widget, :create}, actor, tenant: ctx.a.org)
      refute Ash.can?({ctx.widget_a, :update}, actor, tenant: ctx.a.org)
      refute Ash.can?({ctx.widget_a, :destroy}, actor, tenant: ctx.a.org)
      assert visible(actor, ctx.a.org) == []

      assert {:error, %Ash.Error.Forbidden{}} =
               Widget
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "planted",
                   owner_id: ctx.b.user.id,
                   owner_type: :user,
                   owning_user_id: ctx.b.user.id,
                   owning_business_unit_id: ctx.a.root.id
                 },
                 actor: actor,
                 tenant: ctx.a.org
               )
               |> Ash.create()
    end

    test "is allowed in its own tenant", ctx do
      actor = actor_for(ctx.a)

      assert Ash.can?({Widget, :create}, actor, tenant: ctx.a.org)
      assert Ash.can?({ctx.widget_a, :update}, actor, tenant: ctx.a.org)
      assert visible(actor, ctx.a.org) == [ctx.widget_a.id]
    end

    test "is refused when it was built for no tenant at all", ctx do
      user = ctx.a.user

      actor =
        ActorContext.attach(user, %{
          ActorContext.build(user, tenant: ctx.a.org)
          | organization_id: nil
        })

      refute Ash.can?({Widget, :create}, actor, tenant: ctx.a.org)
    end

    test "is judged as before on a call with no tenant", ctx do
      actor = actor_for(ctx.b)

      # A nil tenant is a separate concern (`global?` multitenancy accepts it);
      # this check does not apply to it and changes nothing there.
      assert Ash.can?({Widget, :read}, actor)
    end
  end

  describe "a person with no business unit" do
    # Their roles are rows of some tenant. Built with no tenant, the role reads
    # used to run with none, and `global? true` let them span every tenant: a role
    # someone held in B became part of a context that belongs to no tenant.
    setup ctx do
      user = register()

      # A role in B the person was given, though B never made them a member.
      grant_global(%{ctx.b | user: user}, privilege(:read))

      %{user: user}
    end

    test "never carries a role held in another tenant", ctx do
      context = ActorContext.build(ctx.user)

      assert context.organization_id == nil
      assert context.grants == %{}
      assert context.team_ids == []
      assert context.shared == %{}
      assert context.task_ids == []
      assert visible(ActorContext.attach(ctx.user, context), ctx.b.org) == []
    end

    test "reads nothing to build it", ctx do
      ref = make_ref()
      test = self()

      :telemetry.attach(
        "xt-no-tenant-#{inspect(ref)}",
        [:ash_enterprise, :repo, :query],
        fn _event, _measurements, %{source: source}, _ -> send(test, {ref, source}) end,
        nil
      )

      try do
        ActorContext.build(ctx.user)
      after
        :telemetry.detach("xt-no-tenant-#{inspect(ref)}")
      end

      refute_received {^ref, _source}
    end

    test "is still who they are, with nothing they may do", ctx do
      context = ActorContext.build(ctx.user)

      assert context.user_id == ctx.user.id
      assert context.principal_ids == [ctx.user.id]
      refute context.system?
    end

    test "a caller that names the tenant vouches for it: the roles are read there", ctx do
      context = ActorContext.build(ctx.user, tenant: ctx.b.org)

      assert %ActorContext.Grant{global?: true} = ActorContext.grant(context, Widget, :read)
    end
  end

  describe "platform principals" do
    test "a system actor crosses tenants", ctx do
      for actor <- [SystemActor.oban(), ActorContext.system(), ActorContext.system(ctx.b.org)] do
        assert Ash.can?({Widget, :create}, actor, tenant: ctx.a.org)
        assert visible(actor, ctx.a.org) == [ctx.widget_a.id]
      end
    end

    test "no actor gains nothing from the check, in either tenant", ctx do
      refute Ash.can?({Widget, :create}, nil, tenant: ctx.a.org)
      refute Ash.can?({Widget, :create}, SystemActor.ai(), tenant: ctx.a.org)
    end
  end

  describe "an automation principal" do
    test "acting for a person is refused in a tenant other than the person's", ctx do
      principal = %{
        ActorContext.build(ctx.b.user, tenant: ctx.b.org)
        | automation: :test_principal
      }

      refute Ash.can?({Widget, :create}, principal, tenant: ctx.a.org)
      assert Ash.can?({Widget, :create}, principal, tenant: ctx.b.org)
    end
  end

  describe "the boundary is on every platform resource" do
    test "first, including resources that declare their own policy set" do
      resources =
        for domain <- Application.fetch_env!(:ash_enterprise, :ash_domains),
            resource <- Ash.Domain.Info.resources(domain),
            AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource),
            do: resource

      # The hand-copied sets are the reason it is injected rather than inherited.
      assert AshEnterprise.Mdm.MatchRuleSet in resources

      missing =
        Enum.reject(resources, fn resource ->
          match?(
            [%{condition: [{AshEnterprise.Security.Checks.ForeignTenant, _}]} | _],
            Ash.Policy.Info.policies(resource)
          )
        end)

      assert missing == []
    end
  end

  # --- fixtures -----------------------------------------------------------------

  defp tenant(name) do
    org = Ash.UUID.generate()

    root =
      BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "#{name} root"},
        authorize?: false,
        tenant: org
      )
      |> Ash.create!()

    user =
      register()
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: root.id},
        authorize?: false
      )
      |> Ash.update!()

    %{org: org, root: root, user: user}
  end

  # A user as registration leaves them: no business unit, so no tenant.
  defp register do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "xt-#{System.unique_integer([:positive])}@example.com",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp actor_for(%{user: user, org: org}),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: org))

  defp privilege(verb) do
    Privilege
    |> Ash.Changeset.for_create(
      :create,
      %{
        resource_name: inspect(Widget),
        access_right: verb,
        name: "prv#{verb}Widget#{System.unique_integer([:positive])}",
        can_be_basic: true,
        can_be_local: true,
        can_be_deep: true,
        can_be_global: true
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp grant_global(%{org: org, root: root, user: user}, privilege) do
    role =
      Role
      |> Ash.Changeset.for_create(
        :create,
        %{name: "role-#{System.unique_integer([:positive])}", owning_business_unit_id: root.id},
        authorize?: false,
        tenant: org
      )
      |> Ash.create!()

    RolePrivilege
    |> Ash.Changeset.for_create(
      :create,
      %{role_id: role.id, privilege_id: privilege.id, depth: :global},
      authorize?: false,
      tenant: org
    )
    |> Ash.create!()

    UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: root.id},
      authorize?: false,
      tenant: org
    )
    |> Ash.create!()
  end

  defp widget(name, %{org: org, root: root, user: user}) do
    Widget
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        owner_id: user.id,
        owner_type: :user,
        owning_user_id: user.id,
        owning_business_unit_id: root.id
      },
      authorize?: false,
      tenant: org
    )
    |> Ash.create!()
  end

  defp visible(actor, tenant) do
    Widget
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end
end
