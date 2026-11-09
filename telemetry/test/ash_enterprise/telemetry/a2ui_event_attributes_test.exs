defmodule AshEnterprise.Telemetry.A2uiEventAttributesTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.A2uiEventAttributes
  alias AshEnterprise.Telemetry.Attributes

  defp resolve(name, context \\ %{}) do
    A2uiEventAttributes.resolve(
      "a2ui:action",
      %{"action" => %{"name" => name, "surfaceId" => "s1", "context" => context}},
      %{view: nil}
    )
  end

  defp action_name(result), do: result[Attributes.ui_action_name()]

  test "a row action reports the action it runs, not the envelope's verb" do
    for verb <- ["invoke", "bulk_invoke", "prompt"] do
      assert action_name(resolve(verb, %{"action" => "activate", "recordId" => "r1"})) ==
               "activate"
    end
  end

  test "any other envelope keeps its own name" do
    assert action_name(resolve("submit_form", %{"action" => "activate"})) == "submit_form"
  end

  test "a row action with no action in its context keeps the verb" do
    assert action_name(resolve("invoke")) == "invoke"
    assert action_name(resolve("invoke", "not-a-map")) == "invoke"
  end

  test "the client-chosen name must look like an action name" do
    for bad <- [%{"a" => 1}, 7, "Acme Corp <jane@acme.test>", String.duplicate("a", 200), ""] do
      assert action_name(resolve("invoke", %{"action" => bad})) == "invoke"
    end
  end

  test "values from the context never reach the attributes" do
    result = resolve("invoke", %{"action" => "activate", "values" => %{"name" => "hunter2"}})
    refute inspect(result) =~ "hunter2"
  end
end
