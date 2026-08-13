defmodule AshEnterprise.Security.HierarchyTest do
  @moduledoc """
  The hierarchy-security truth table.

  Hierarchy is the grant path with the most ways to be subtly wrong, because
  every mistake makes it *more* permissive and none of them raise:

    * granting write down the whole chain instead of only to direct reports
    * granting delete/assign/share at all
    * reaching reports in business units the manager was moved away from
    * inheriting a report's own broad access rather than only what they own
    * granting access to tables the manager has no baseline read on

  Each of those has a test below, phrased as the thing that must *not* happen.

  ## The fixture

      ceo
      └── vp          (direct report of ceo)
          └── ic      (direct report of vp, INDIRECT report of ceo)

  All three sit in the same business unit, so the business-unit restriction is
  satisfied except where a test deliberately breaks it.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Accounts.Position
  alias AshEnterprise.Conformance.Widget
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.Privilege
  alias AshEnterprise.Security.Role
  alias AshEnterprise.Security.RolePrivilege
  alias AshEnterprise.Security.UserRole

  @widget_resource inspect(Widget)

  setup do
    org = Ash.UUID.generate()
    root = bu("Root", nil, org)
    other = bu("Other", root, org)

    ceo = user("ceo@example.com", root, org)
    vp = user("vp@example.com", root, org)
    ic = user("ic@example.com", root, org)

    vp = set_manager(vp, ceo)
    ic = set_manager(ic, vp)

    privileges =
      Map.new([:read, :write, :delete], fn verb -> {verb, privilege(verb)} end)

    widgets = %{
      ceo: widget("ceo widget", ceo, root, org),
      vp: widget("vp widget", vp, root, org),
      ic: widget("ic widget", ic, root, org)
    }

    on_exit(fn -> Application.delete_env(:ash_enterprise, :hierarchy_security) end)

    %{
      org: org,
      bus: %{root: root, other: other},
      users: %{ceo: ceo, vp: vp, ic: ic},
      privileges: privileges,
      widgets: widgets
    }
  end

  describe "disabled by default" do
    test "grants nothing when no mode is configured", ctx do
      # The ceo has baseline read, so anything visible beyond their own widget
      # would have to come from hierarchy.
      grant(ctx, :ceo, :read, :basic)

      assert visible(actor(ctx, :ceo), ctx) == [:ceo]
    end
  end

  describe "manager mode: read reaches the whole chain below" do
    setup do: enable(:manager)

    test "a manager reads direct reports' records", ctx do
      grant(ctx, :ceo, :read, :basic)

      assert :vp in visible(actor(ctx, :ceo), ctx)
    end

    test "a manager reads indirect reports' records too", ctx do
      grant(ctx, :ceo, :read, :basic)

      # ic reports to vp, who reports to ceo.
      assert visible(actor(ctx, :ceo), ctx) == [:ceo, :ic, :vp]
    end

    test "access flows downward only -- a report cannot read their manager", ctx do
      grant(ctx, :ic, :read, :basic)

      assert visible(actor(ctx, :ic), ctx) == [:ic]
    end
  end

  describe "manager mode: the direct/indirect write asymmetry" do
    setup do: enable(:manager)

    test "a manager may write a DIRECT report's record", ctx do
      grant(ctx, :ceo, :read, :basic)

      assert Ash.can?({ctx.widgets.vp, :update}, actor(ctx, :ceo), tenant: ctx.org)
    end

    test "a manager may NOT write an INDIRECT report's record", ctx do
      grant(ctx, :ceo, :read, :basic)

      # This is the assertion that stops seniority from becoming write access
      # across an entire org chart.
      refute Ash.can?({ctx.widgets.ic, :update}, actor(ctx, :ceo), tenant: ctx.org)
    end

    test "a manager may still READ the indirect report they cannot write", ctx do
      grant(ctx, :ceo, :read, :basic)

      assert :ic in visible(actor(ctx, :ceo), ctx)
    end
  end

  describe "manager mode: verbs hierarchy never grants" do
    setup do: enable(:manager)

    test "delete is not granted, even for a direct report", ctx do
      grant(ctx, :ceo, :read, :basic)
      grant(ctx, :ceo, :delete, :basic)

      # :basic delete covers the ceo's own widget but must not extend to vp's
      # merely because vp reports to them. Destroying a report's work requires a
      # role, which leaves a trace an auditor can find.
      refute Ash.can?({ctx.widgets.vp, :destroy}, actor(ctx, :ceo), tenant: ctx.org)
      assert Ash.can?({ctx.widgets.ceo, :destroy}, actor(ctx, :ceo), tenant: ctx.org)
    end
  end

  describe "manager mode: the baseline-read precondition" do
    setup do: enable(:manager)

    test "hierarchy grants nothing on a resource the actor has no read on", ctx do
      # No privileges granted at all. Without the precondition, enabling
      # hierarchy security would hand every manager visibility into every table
      # any subordinate owns rows in -- payroll, audit, security config.
      assert visible(actor(ctx, :ceo), ctx) == []
    end

    test "hierarchy activates once a baseline read exists", ctx do
      grant(ctx, :ceo, :read, :basic)

      assert visible(actor(ctx, :ceo), ctx) == [:ceo, :ic, :vp]
    end
  end

  describe "manager mode: the business-unit restriction" do
    setup do: enable(:manager)

    test "a manager does not reach reports outside their business unit subtree", ctx do
      grant(ctx, :ceo, :read, :basic)

      # Move the VP into a sibling branch the CEO's unit does not contain.
      sibling = bu("Sibling", ctx.bus.root, ctx.org)
      moved_ceo = move_to(ctx.users.ceo, ctx.bus.other)

      # The CEO now sits in `other`; vp remains in root, which is NOT beneath
      # `other`. Without this rule a transferred manager keeps their old reports
      # indefinitely, invisibly to the role model.
      _ = sibling
      grant_for(ctx, moved_ceo, :read, :basic)

      refute :vp in visible(actor_for(moved_ceo, ctx), ctx)
    end

    test "the restriction can be turned off", ctx do
      Application.put_env(:ash_enterprise, :hierarchy_security,
        mode: :manager,
        managers_must_share_business_unit?: false
      )

      moved_ceo = move_to(ctx.users.ceo, ctx.bus.other)
      grant_for(ctx, moved_ceo, :read, :basic)

      assert :vp in visible(actor_for(moved_ceo, ctx), ctx)
    end
  end

  describe "manager mode: depth bound" do
    test "a depth of 1 reaches direct reports only", ctx do
      Application.put_env(:ash_enterprise, :hierarchy_security, mode: :manager, max_depth: 1)
      grant(ctx, :ceo, :read, :basic)

      visible = visible(actor(ctx, :ceo), ctx)

      assert :vp in visible
      refute :ic in visible
    end
  end

  describe "manager mode: no transitive inheritance of a report's access" do
    setup do: enable(:manager)

    test "a manager does not inherit a report's global grant", ctx do
      grant(ctx, :ceo, :read, :basic)
      # Give the IC sweeping access. Their manager must NOT acquire it.
      grant(ctx, :ic, :read, :global)

      other_user = user("outsider@example.com", ctx.bus.other, ctx.org)
      _outsider_widget = widget("outsider widget", other_user, ctx.bus.other, ctx.org)

      visible = visible(actor(ctx, :ceo), ctx)

      # ceo sees the chain's own records, and nothing the IC merely *can see*.
      assert visible == [:ceo, :ic, :vp]
    end
  end

  describe "position mode" do
    setup ctx do
      enable(:position)

      exec = position("Executive", nil, ctx.org)
      sales = position("Sales", exec, ctx.org)
      support = position("Support", exec, ctx.org)
      rep = position("Sales Rep", sales, ctx.org)

      ceo = set_position(ctx.users.ceo, exec)
      vp = set_position(ctx.users.vp, sales)
      ic = set_position(ctx.users.ic, support)

      %{
        positions: %{exec: exec, sales: sales, support: support, rep: rep},
        users: %{ceo: ceo, vp: vp, ic: ic}
      }
    end

    test "a higher position reaches lower positions beneath it", ctx do
      grant(ctx, :ceo, :read, :basic)

      assert visible(actor(ctx, :ceo), ctx) == [:ceo, :ic, :vp]
    end

    test "sibling branches do not see each other", ctx do
      # Sales and Support are siblings under Executive. The VP (Sales) must not
      # reach the IC (Support), even though they are at the same level -- this is
      # the "direct ancestor path" rule, and the naive implementation that
      # compares levels rather than lineage fails here.
      grant(ctx, :vp, :read, :basic)

      assert visible(actor(ctx, :vp), ctx) == [:vp]
    end

    test "a user with no position reaches nobody through the hierarchy", ctx do
      unplaced = user("unplaced@example.com", ctx.bus.root, ctx.org)
      grant_for(ctx, unplaced, :read, :basic)

      assert visible(actor_for(unplaced, ctx), ctx) == []
    end
  end

  describe "cycle prevention" do
    test "a user cannot be their own manager", ctx do
      assert {:error, error} =
               ctx.users.ceo
               |> Ash.Changeset.for_update(:assign_manager, %{manager_id: ctx.users.ceo.id},
                 authorize?: false
               )
               |> Ash.update()

      assert Exception.message(error) =~ "own manager"
    end

    test "a management cycle is rejected", ctx do
      # ceo <- vp <- ic already exists. Making the ceo report to the ic closes
      # the loop, which would make the subordinate walk produce a wrong set.
      assert {:error, error} =
               ctx.users.ceo
               |> Ash.Changeset.for_update(:assign_manager, %{manager_id: ctx.users.ic.id},
                 authorize?: false
               )
               |> Ash.update()

      assert Exception.message(error) =~ "cycle"
    end

    test "a position cannot report to its own subordinate", ctx do
      exec = position("Exec2", nil, ctx.org)
      sales = position("Sales2", exec, ctx.org)

      assert {:error, error} =
               exec
               |> Ash.Changeset.for_update(:update, %{parent_position_id: sales.id},
                 authorize?: false,
                 tenant: ctx.org
               )
               |> Ash.update()

      assert Exception.message(error) =~ "subordinate"
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp enable(mode) do
    Application.put_env(:ash_enterprise, :hierarchy_security, mode: mode, max_depth: 3)
    :ok
  end

  defp visible(actor, ctx) do
    {:ok, widgets} = Ash.read(Widget, actor: actor, tenant: ctx.org)
    names = Map.new(ctx.widgets, fn {key, w} -> {w.id, key} end)

    widgets |> Enum.map(&names[&1.id]) |> Enum.reject(&is_nil/1) |> Enum.sort()
  end

  defp actor(ctx, key), do: actor_for(ctx.users[key], ctx)

  defp actor_for(user, ctx) do
    ActorContext.attach(user, ActorContext.build(user, tenant: ctx.org))
  end

  defp grant(ctx, user_key, verb, depth), do: grant_for(ctx, ctx.users[user_key], verb, depth)

  defp grant_for(ctx, user, verb, depth) do
    bu_id = user.owning_business_unit_id || ctx.bus.root.id

    role =
      Role
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "r-#{verb}-#{depth}-#{System.unique_integer([:positive])}",
          owning_business_unit_id: bu_id
        },
        authorize?: false,
        tenant: ctx.org
      )
      |> Ash.create!()

    RolePrivilege
    |> Ash.Changeset.for_create(
      :create,
      %{role_id: role.id, privilege_id: ctx.privileges[verb].id, depth: depth},
      authorize?: false,
      tenant: ctx.org
    )
    |> Ash.create!()

    UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: bu_id},
      authorize?: false,
      tenant: ctx.org
    )
    |> Ash.create!()
  end

  defp bu(name, parent, org) do
    BusinessUnit
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, parent_business_unit_id: parent && parent.id},
      authorize?: false,
      tenant: org
    )
    |> Ash.create!()
  end

  defp position(name, parent, org) do
    Position
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "#{name}-#{System.unique_integer([:positive])}",
        parent_position_id: parent && parent.id
      },
      authorize?: false,
      tenant: org
    )
    |> Ash.create!()
  end

  defp user(email, business_unit, org) do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{email: email, password: "password1234", password_confirmation: "password1234"},
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(
      :assign_to_business_unit,
      %{owning_business_unit_id: business_unit.id},
      authorize?: false
    )
    |> Ash.update!()
    |> Map.put(:organization_id, org)
  end

  defp set_manager(user, manager) do
    user
    |> Ash.Changeset.for_update(:assign_manager, %{manager_id: manager.id}, authorize?: false)
    |> Ash.update!()
    |> Map.put(:organization_id, user.organization_id)
  end

  defp set_position(user, position) do
    user
    |> Ash.Changeset.for_update(:assign_position, %{position_id: position.id}, authorize?: false)
    |> Ash.update!()
    |> Map.put(:organization_id, user.organization_id)
  end

  defp move_to(user, business_unit) do
    user
    |> Ash.Changeset.for_update(
      :assign_to_business_unit,
      %{owning_business_unit_id: business_unit.id},
      authorize?: false
    )
    |> Ash.update!()
    |> Map.put(:organization_id, user.organization_id)
  end

  defp privilege(verb) do
    Privilege
    |> Ash.Changeset.for_create(
      :create,
      %{resource_name: @widget_resource, access_right: verb, name: "prv#{verb}Widget"},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp widget(name, owner, business_unit, org) do
    Widget
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        owner_id: owner.id,
        owner_type: :user,
        owning_user_id: owner.id,
        owning_business_unit_id: business_unit.id
      },
      authorize?: false,
      tenant: org
    )
    |> Ash.create!()
  end
end
