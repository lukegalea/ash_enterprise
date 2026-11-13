defmodule AshEnterpriseWeb.A2uiMessageTest do
  @moduledoc """
  The one wire a surface speaks (A2UI 1.0): an `ashAction` function call, answered by an
  `agentFunctionResponse` that comes last. A plain `action` event and any other function
  are refused, and nothing runs for either.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.A2uiMessage
  alias AshEnterpriseWeb.A2ui.{CredentialUI, Host}

  defp feedback(messages) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => "/ui/feedback", "value" => value}} -> value
      _other -> nil
    end)
  end

  test "an ashAction call is answered by one agentFunctionResponse, last, with the call's id" do
    message = A2uiMessage.ash_action(CredentialUI, "query", %{"component" => "table"})
    call_id = get_in(message, ["callAgentFunction", "functionCallId"])

    {:ok, messages} = Host.act(CredentialUI, message, [])

    assert %{"agentFunctionResponse" => %{"functionCallId" => ^call_id}} = List.last(messages)

    assert 1 ==
             Enum.count(messages, &match?(%{"agentFunctionResponse" => _response}, &1))
  end

  test "a plain action event is refused: UNKNOWN_FUNCTION feedback and no function response" do
    plain = %{
      "version" => "1.0",
      "action" => %{
        "name" => "invoke",
        "surfaceId" => "credentials",
        "sourceComponentId" => "data_grid",
        "timestamp" => "2030-01-01T00:00:00Z",
        "context" => %{"action" => "request_activation", "recordId" => Ash.UUID.generate()}
      }
    }

    assert {:error, messages} = Host.act(CredentialUI, plain, [])
    assert %{"kind" => "error", "code" => "UNKNOWN_FUNCTION"} = feedback(messages)
    refute Enum.any?(messages, &Map.has_key?(&1, "agentFunctionResponse"))
    assert AshEnterprise.Channels.message_target(CredentialUI, plain) |> elem(1) == nil
  end

  test "an unknown function is answered with an UNKNOWN_FUNCTION error" do
    message =
      "credentials"
      |> A2uiMessage.ash_action("invoke", %{})
      |> put_in(["callAgentFunction", "callFunction", "@call"], "dropTables")

    call_id = get_in(message, ["callAgentFunction", "functionCallId"])

    assert {:error, messages} = Host.act(CredentialUI, message, [])

    assert %{
             "agentFunctionResponse" => %{
               "functionCallId" => ^call_id,
               "error" => %{"code" => "UNKNOWN_FUNCTION"}
             }
           } = List.last(messages)

    assert AshEnterprise.Channels.message_target(CredentialUI, message) |> elem(1) == nil
  end

  test "ashAction under another catalog is refused too" do
    message =
      "credentials"
      |> A2uiMessage.ash_action("query", %{})
      |> put_in(["callAgentFunction", "callFunction", "catalogId"], "https://example.test/c")

    assert {:error, messages} = Host.act(CredentialUI, message, [])
    assert %{"kind" => "error", "code" => "UNKNOWN_FUNCTION"} = feedback(messages)
  end

  test "A2uiMessage.parse reads an ashAction call and nothing else" do
    message = A2uiMessage.ash_action("s", "invoke", %{"a" => 1})
    assert A2uiMessage.parse(message) == {:ok, "invoke", %{"a" => 1}}
    assert A2uiMessage.parse(%{"version" => "1.0", "action" => %{"name" => "invoke"}}) == :error
    assert A2uiMessage.parse(%{"name" => "invoke", "context" => %{}}) == :error
  end
end
