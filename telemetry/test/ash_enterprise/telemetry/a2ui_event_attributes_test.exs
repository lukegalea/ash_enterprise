defmodule AshEnterprise.Telemetry.A2uiEventAttributesTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.A2uiEventAttributes
  alias AshEnterprise.Telemetry.Attributes

  defmodule SurfaceView do
    def __ash_a2ui_config__, do: %{ui: AshEnterprise.Telemetry.A2uiEventAttributesTest.AccountsUI}
  end

  defp envelope(name, context) do
    %{"action" => %{"name" => name, "surfaceId" => "s1", "context" => context}}
  end

  defp resolve(name, context, opts \\ []) do
    A2uiEventAttributes.resolve(
      "a2ui:action",
      envelope(name, context),
      %{view: SurfaceView},
      opts
    )
  end

  defp action_name(result), do: result[Attributes.ui_action_name()]

  test "an undeclared client-chosen name reports the verb and appears nowhere" do
    result =
      A2uiEventAttributes.resolve(
        "a2ui:action",
        envelope("invoke", %{"action" => "drop_tables", "recordId" => "r1"}),
        %{view: SurfaceView}
      )

    assert action_name(result) == "invoke"
    refute inspect(result) =~ "drop_tables"
  end

  test "a row action reports the action it runs when the surface declares it" do
    for verb <- ["invoke", "bulk_invoke", "prompt"] do
      context = %{"action" => "activate", "recordId" => "r1"}
      assert action_name(resolve(verb, context, declared: [:activate])) == "activate"
      assert action_name(resolve(verb, context, declared: ["activate"])) == "activate"
      assert action_name(resolve(verb, context, declared: [:deactivate])) == verb
    end
  end

  test "the declared set can come from a function or an MFA, given the UI module and surface" do
    test_pid = self()

    declared = fn ui, surface_id ->
      send(test_pid, {:asked, ui, surface_id})
      [:activate]
    end

    assert action_name(resolve("invoke", %{"action" => "activate"}, declared: declared)) ==
             "activate"

    assert_received {:asked, AshEnterprise.Telemetry.A2uiEventAttributesTest.AccountsUI, "s1"}

    mfa = {__MODULE__, :declared_actions, [[:archive]]}
    assert action_name(resolve("invoke", %{"action" => "archive"}, declared: mfa)) == "archive"
    assert action_name(resolve("invoke", %{"action" => "activate"}, declared: mfa)) == "invoke"
  end

  def declared_actions(_ui, "s1", names), do: names

  test "without ash_a2ui loaded and no declared set, a row action reports its verb" do
    assert action_name(resolve("invoke", %{"action" => "activate"})) == "invoke"
    assert A2uiEventAttributes.declared_on_ui(nil, "s1") == []
  end

  test "any other envelope keeps its own name" do
    assert action_name(resolve("submit_form", %{"action" => "activate"}, declared: [:activate])) ==
             "submit_form"
  end

  test "a row action with no action in its context keeps the verb" do
    assert action_name(resolve("invoke", %{}, declared: [:activate])) == "invoke"
    assert action_name(resolve("invoke", "not-a-map", declared: [:activate])) == "invoke"
  end

  test "a non-name action in the context reports the verb" do
    for bad <- [%{"a" => 1}, 7, String.duplicate("a", 200), ""] do
      assert action_name(resolve("invoke", %{"action" => bad}, declared: [:activate])) == "invoke"
    end
  end

  test "values from the context never reach the attributes" do
    result =
      resolve("invoke", %{"action" => "activate", "values" => %{"name" => "hunter2"}},
        declared: [:activate]
      )

    refute inspect(result) =~ "hunter2"
    assert result[Attributes.ui_action_resource()] =~ "AccountsUI"
  end
end
