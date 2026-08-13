defmodule AshEnterpriseWeb.A2uiSurfacesTest do
  @moduledoc """
  Verifies the A2UI surfaces produce valid protocol payloads, and — more
  importantly — that they are filtered by the same policies as everything else.

  A surface that renders is not the same as a surface that renders *the right
  rows*. `ash_a2ui` resolves data by running the resource's own read actions
  with the actor it is handed, so a mistake in the `actor_fn` seam would produce
  a working-looking screen showing data the viewer should not see. That is the
  failure this file exists to catch.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.BusinessUnitUI
  alias AshEnterpriseWeb.A2ui.RoleUI
  alias AshEnterpriseWeb.A2ui.UserUI

  setup do
    seeded =
      AshEnterprise.Platform.Seeder.seed_tenant(
        unique_name: "a2ui-#{System.unique_integer([:positive])}"
      )

    admin =
      ActorContext.attach(
        seeded.user,
        ActorContext.build(seeded.user, tenant: seeded.organization.id)
      )

    %{seeded: seeded, admin: admin, tenant: seeded.organization.id}
  end

  describe "surface construction" do
    for {mod, name} <- [{UserUI, "users"}, {RoleUI, "roles"}, {BusinessUnitUI, "business_units"}] do
      test "#{name} builds a valid A2UI message list", ctx do
        messages =
          AshA2ui.Info.build_surface(unquote(mod), actor: ctx.admin, tenant: ctx.tenant)

        assert is_list(messages)
        assert messages != []

        # A2UI is UI-as-data: the server emits a description of a surface, the
        # client renders it from a catalog it already trusts. Every message must
        # therefore be a plain map -- no markup, no script.
        assert Enum.all?(messages, &is_map/1)
      end
    end
  end

  describe "surfaces are policy-filtered, not just rendered" do
    test "an actor with no roles sees no rows", ctx do
      stranger =
        AshEnterprise.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "stranger-#{System.unique_integer([:positive])}@example.com",
            password: "password1234",
            password_confirmation: "password1234"
          },
          authorize?: false
        )
        |> Ash.create!()
        |> Ash.Changeset.for_update(
          :assign_to_business_unit,
          %{owning_business_unit_id: ctx.seeded.business_unit.id},
          authorize?: false
        )
        |> Ash.update!()
        |> Map.put(:organization_id, ctx.tenant)

      stranger_actor =
        ActorContext.attach(stranger, ActorContext.build(stranger, tenant: ctx.tenant))

      admin_rows = row_count(RoleUI, ctx.admin, ctx.tenant)
      stranger_rows = row_count(RoleUI, stranger_actor, ctx.tenant)

      # The seeded administrator holds a global grant, so they see the role.
      assert admin_rows > 0

      # The stranger holds nothing. If this ever returns rows, the actor_fn seam
      # is broken and every A2UI screen is leaking.
      assert stranger_rows == 0
    end
  end

  # The data model carries the rows; the surface carries the layout. Counting
  # rows means digging into the data model rather than the component tree.
  defp row_count(ui, actor, tenant) do
    ui
    |> AshA2ui.Info.build_data_model(actor: actor, tenant: tenant)
    |> collect_lists()
    |> Enum.map(&length/1)
    |> Enum.max(fn -> 0 end)
  end

  defp collect_lists(value, acc \\ [])
  defp collect_lists(value, acc) when is_list(value), do: [value | acc]

  defp collect_lists(%{} = value, acc) do
    Enum.reduce(value, acc, fn {_k, v}, acc -> collect_lists(v, acc) end)
  end

  defp collect_lists(_other, acc), do: acc
end
