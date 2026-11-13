defmodule AshEnterpriseWeb.A2uiEventAttributesTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.A2uiEventAttributes
  alias AshEnterprise.Telemetry.Attributes

  defmodule AccountsView do
    def __ash_a2ui_config__, do: %{ui: AshEnterpriseWeb.A2ui.AccountsUI}
  end

  defp action_name(verb, action) do
    message =
      AshEnterprise.A2uiMessage.ash_action("accounts", verb, %{
        "action" => action,
        "recordId" => "r1"
      })

    A2uiEventAttributes.resolve("a2ui:message", message, %{view: AccountsView})[
      Attributes.ui_action_name()
    ]
  end

  test "the row and bulk actions a surface declares are read from its UI module" do
    assert action_name("invoke", "activate") == "activate"
    assert action_name("bulk_invoke", "sync_now") == "sync_now"
  end

  test "a name the surface does not declare reports the verb" do
    assert action_name("invoke", "drop_tables") == "invoke"
    assert action_name("prompt", "destroy") == "prompt"
  end
end
