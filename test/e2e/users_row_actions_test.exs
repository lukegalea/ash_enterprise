defmodule AshEnterpriseWeb.E2E.UsersRowActionsTest do
  @moduledoc """
  What the generated `users` row-action tests (`test/e2e/surfaces_test.exs`) take on
  trust, checked on its own:

    * deactivating asks first: the row button opens the confirmation dialog and
      changes nothing, and only the dialog's confirm control deactivates;
    * the audit proof can fail: with the audit row out of reach
      (`AshEnterpriseWeb.E2E.MissingAuditSurfaces`) the generated test for
      deactivate fails on it, after the click, the confirmation and the span chain
      have all passed.
  """

  use AshBrowserTests.Case, async: true

  alias AshBrowserTests.Browser
  alias AshBrowserTests.RowActions
  alias AshBrowserTests.Surface
  alias AshEnterprise.Accounts.User
  alias AshEnterpriseWeb.E2E.Login
  alias AshEnterpriseWeb.E2E.MissingAuditSurfaces
  alias AshEnterpriseWeb.E2E.Surfaces

  test "deactivating asks first, and only the dialog's confirm control deactivates", context do
    deactivate =
      Enum.find(Surfaces.manifest("users").row_actions, &(&1.ash_action == :deactivate))

    assert %{confirm: :destructive, confirm_label: "Deactivate"} = deactivate

    row = Surfaces.row_for(%Surface{id: "users"}, deactivate, context)

    conn =
      context.conn
      |> Login.as(row.admin)
      |> PhoenixTest.visit("/app/users")
      |> Browser.assert_connected()
      |> RowActions.perform(%{id: row.id, text: row.text, inputs: %{}}, %{
        deactivate
        | confirm_label: nil
      })
      |> Browser.assert_deep("[role=dialog]", text: "Deactivate this record?")
      |> Browser.refute_deep("[role=dialog]", text: "cannot be undone")

    assert Ash.get!(User, row.id, authorize?: false).lifecycle_status == :active

    conn
    |> RowActions.confirm(deactivate)
    |> Browser.assert_deep(~s([data-a2ui-row-id="#{row.id}"]), text: "Inactive", timeout: 15_000)

    assert Ash.get!(User, row.id, authorize?: false).lifecycle_status == :inactive
  end

  test "a generated row-action test fails when its audit row is missing", context do
    assert_raise ExUnit.AssertionError, ~r/no audit row for deactivate/, fn ->
      AshBrowserTests.Surfaces.run(
        MissingAuditSurfaces,
        Map.put(context, :generated, {:action, "users", "row:table.deactivate"})
      )
    end
  end
end
