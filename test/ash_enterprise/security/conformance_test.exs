defmodule AshEnterprise.Security.ConformanceTest do
  @moduledoc """
  The authorization truth table, executable.

  This is less a test of our implementation than a machine-checkable copy of the
  Dataverse specification. When the model surprises you, read this file first —
  it says what each depth is supposed to reach, case by case.

  ## The fixture

      root
      ├── emea
      │   └── uk
      └── apac

      alice  in emea
      bob    in uk      (beneath alice)
      carol  in apac    (a sibling branch, never beneath alice)

  Widgets are created owned by each user, in that user's business unit. So for a
  grant held by alice scoped to emea:

  | Depth | alice's widget | bob's (child BU) | carol's (sibling BU) |
  |---|---|---|---|
  | `:basic` | ✅ owns it | ❌ | ❌ |
  | `:local` | ✅ emea | ❌ uk ≠ emea | ❌ |
  | `:deep` | ✅ | ✅ uk ⊂ emea | ❌ apac ⊄ emea |
  | `:global` | ✅ | ✅ | ✅ |

  The `:deep` / carol row is the one that matters most: a bug in the materialized
  path shows up exactly there, as access leaking across sibling branches.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit
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
    emea = bu("EMEA", root, org)
    uk = bu("UK", emea, org)
    apac = bu("APAC", root, org)

    alice = user("alice@example.com", emea, org)
    bob = user("bob@example.com", uk, org)
    carol = user("carol@example.com", apac, org)

    privileges =
      Map.new([:read, :write, :create, :delete], fn verb ->
        {verb, privilege(verb, org)}
      end)

    widgets = %{
      alice: widget("alice's widget", alice, emea, org),
      bob: widget("bob's widget", bob, uk, org),
      carol: widget("carol's widget", carol, apac, org)
    }

    %{
      org: org,
      bus: %{root: root, emea: emea, uk: uk, apac: apac},
      users: %{alice: alice, bob: bob, carol: carol},
      privileges: privileges,
      widgets: widgets
    }
  end

  # --- the truth table --------------------------------------------------------

  describe "depth semantics for a grant scoped to EMEA" do
    test "basic reaches only records the actor owns", ctx do
      actor = with_role(ctx, :alice, :read, :basic, ctx.bus.emea)

      assert visible(actor, ctx) == [:alice]
    end

    test "local reaches the actor's business unit, but not child units", ctx do
      actor = with_role(ctx, :alice, :read, :local, ctx.bus.emea)

      # bob is in UK, a *child* of EMEA. Local stops at EMEA.
      assert visible(actor, ctx) == [:alice]
    end

    test "deep reaches the business unit and everything beneath it", ctx do
      actor = with_role(ctx, :alice, :read, :deep, ctx.bus.emea)

      # UK is beneath EMEA, so bob's widget is reachable. APAC is a sibling
      # branch, so carol's is not -- this is the assertion that catches a broken
      # materialized path.
      assert visible(actor, ctx) == [:alice, :bob]
    end

    test "global reaches everything in the tenant", ctx do
      actor = with_role(ctx, :alice, :read, :global, ctx.bus.emea)

      assert visible(actor, ctx) == [:alice, :bob, :carol]
    end

    test "no role at all reaches nothing -- the model fails closed", ctx do
      actor = context_for(ctx, :alice)

      assert visible(actor, ctx) == []
    end
  end

  describe "depth is a total order: wider depths subsume narrower ones" do
    test "deep scoped at the root reaches every branch", ctx do
      actor = with_role(ctx, :alice, :read, :deep, ctx.bus.root)

      assert visible(actor, ctx) == [:alice, :bob, :carol]
    end

    test "local scoped at a child unit does not reach the parent", ctx do
      actor = with_role(ctx, :alice, :read, :local, ctx.bus.uk)

      # A grant scoped to UK reaches bob (in UK) and not alice (in EMEA), even
      # though alice is the actor -- scope is about the record, not the actor.
      assert visible(actor, ctx) == [:bob]
    end
  end

  describe "grants are additive and never subtract" do
    test "two narrow grants union rather than conflict", ctx do
      # :basic (own records) plus :local scoped to APAC. Neither alone reaches
      # both alice's and carol's widgets; together they must reach exactly those
      # two, and still not bob's.
      grant_role(ctx, :alice, :read, :basic, ctx.bus.emea)
      grant_role(ctx, :alice, :read, :local, ctx.bus.apac)
      actor = context_for(ctx, :alice)

      assert visible(actor, ctx) == [:alice, :carol]
    end

    test "a wider grant added later never reduces access", ctx do
      grant_role(ctx, :alice, :read, :basic, ctx.bus.emea)
      before = visible(context_for(ctx, :alice), ctx)

      grant_role(ctx, :alice, :read, :global, ctx.bus.emea)
      after_widening = visible(context_for(ctx, :alice), ctx)

      assert before == [:alice]
      assert after_widening == [:alice, :bob, :carol]
      # The defining property of a union: nothing that was visible became hidden.
      assert Enum.all?(before, &(&1 in after_widening))
    end
  end

  describe "verbs are independent" do
    test "a read grant does not confer write", ctx do
      actor = with_role(ctx, :alice, :read, :global, ctx.bus.emea)

      assert Ash.can?({Widget, :read}, actor, tenant: ctx.org)
      refute Ash.can?({ctx.widgets.alice, :update}, actor, tenant: ctx.org)
    end

    test "a write grant does not confer read", ctx do
      actor = with_role(ctx, :alice, :write, :global, ctx.bus.emea)

      assert visible(actor, ctx) == []
    end
  end

  describe "system actors" do
    test "bypass the role model entirely", ctx do
      actor = AshEnterprise.Platform.SystemActor.oban()

      assert visible(actor, ctx) == [:alice, :bob, :carol]
    end
  end

  describe "tenant isolation is independent of authorization" do
    test "a global grant does not cross tenants", ctx do
      other_org = Ash.UUID.generate()
      other_bu = bu("Other Root", nil, other_org)
      other_user = user("dave@example.com", other_bu, other_org)
      _other_widget = widget("dave's widget", other_user, other_bu, other_org)

      actor = with_role(ctx, :alice, :read, :global, ctx.bus.emea)

      # Global means "everything in the tenant", never "everything".
      assert visible(actor, ctx) == [:alice, :bob, :carol]
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp visible(actor, ctx) do
    {:ok, widgets} = Ash.read(Widget, actor: actor, tenant: ctx.org)

    names = Map.new(ctx.widgets, fn {key, widget} -> {widget.id, key} end)

    widgets
    |> Enum.map(&names[&1.id])
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp with_role(ctx, user_key, verb, depth, scoping_bu) do
    grant_role(ctx, user_key, verb, depth, scoping_bu)
    context_for(ctx, user_key)
  end

  defp grant_role(ctx, user_key, verb, depth, scoping_bu) do
    user = ctx.users[user_key]

    role =
      Role
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "role-#{verb}-#{depth}-#{System.unique_integer([:positive])}",
          owning_business_unit_id: scoping_bu.id
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
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: scoping_bu.id},
      authorize?: false,
      tenant: ctx.org
    )
    |> Ash.create!()
  end

  defp context_for(ctx, user_key) do
    user = ctx.users[user_key]
    ActorContext.attach(user, ActorContext.build(user, tenant: ctx.org))
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

  defp privilege(verb, _org) do
    Privilege
    |> Ash.Changeset.for_create(
      :create,
      %{
        resource_name: @widget_resource,
        access_right: verb,
        name: "prv#{verb}Widget",
        can_be_basic: true,
        can_be_local: true,
        can_be_deep: true,
        can_be_global: true
      },
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
