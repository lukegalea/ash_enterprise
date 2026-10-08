defmodule AshEnterprise.AcpHostTest do
  @moduledoc """
  The E3 wire gate as a regression: the full ACP server flow (initialize →
  session/new → "list business units") against the real host seams and a real
  seeded tenant must stream an authorized read as `tool_call_update` rows plus
  an `available_commands_update` whose `_meta.a2ui` surface carries non-empty
  records. ExUnit prints the actual read error on failure.
  """

  use AshEnterprise.DataCase, async: false

  alias AshAcp.Server
  alias AshEnterprise.Acp
  alias AshEnterprise.Acp.SessionStore
  alias AshEnterprise.Platform.Seeder

  setup do
    suffix = System.unique_integer([:positive])
    org_name = "Acp Test #{suffix}"
    org_unique_name = "acp-test-#{suffix}"

    seeded =
      Seeder.seed_tenant(
        name: org_name,
        unique_name: org_unique_name,
        email: "acp-admin-#{suffix}@example.com"
      )

    Application.put_env(:ash_acp, :session_store, Acp.SessionStore)
    Application.put_env(:ash_acp, :prompt_target, Acp.SessionStore)
    Application.put_env(:ash_acp, :permission_request, Acp.Approvals)
    Application.put_env(:ash_acp, :surface_provider, Acp.Surfaces)

    original = Application.get_all_env(:ash_acp)

    on_exit(fn ->
      Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end)
    end)

    %{seeded: seeded, email: "acp-admin-#{suffix}@example.com"}
  end

  test "business-unit prompt streams rows and an A2UI surface", %{email: email, seeded: seeded} do
    # The session actor is the seeded admin; SessionStore resolves the actor by
    # the fixed operator email, so point the deployment's operator at this
    # test's admin for the duration.
    Application.put_env(:ash_enterprise, :acp_operator_email, email)

    on_exit(fn ->
      Application.delete_env(:ash_enterprise, :acp_operator_email)
    end)

    state0 = Server.new(AshAcp.config())

    {resp, _, state1} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => 1, "clientCapabilities" => %{}}
        },
        state0
      )

    assert resp["result"]["protocolVersion"] == 1

    {resp2, _, state2} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "session/new",
          "params" => %{"cwd" => "/tmp"}
        },
        state1
      )

    sid = resp2["result"]["sessionId"]

    {resp3, updates, _state3} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => sid,
            "prompt" => [%{"type" => "text", "text" => "list business units"}]
          }
        },
        state2
      )

    # The seeded admin is authorized for the read: no permission request, and
    # the turn completes with the rows.
    refute Enum.any?(updates, &(&1["method"] == "session/request_permission")),
           "authorized admin must not trigger a permission request"

    tool_calls =
      Enum.filter(updates, fn u ->
        u["method"] == "session/update" and
          u["params"]["update"]["sessionUpdate"] == "tool_call_update"
      end)

    assert tool_calls != [],
           "expected tool_call_update rows, got: #{inspect(Enum.map(updates, & &1["method"]))}"

    assert resp3["result"]["stopReason"] == "end_turn"

    closing =
      updates
      |> Enum.filter(&(&1["method"] == "session/update"))
      |> Enum.find(&(&1["params"]["update"]["sessionUpdate"] == "available_commands_update"))

    assert closing, "expected a closing available_commands_update"

    a2ui = get_in(closing, ["params", "update", "_meta", "a2ui"])
    assert a2ui

    data_model = Enum.find(a2ui, &Map.has_key?(&1, "updateDataModel"))
    assert data_model

    records = data_model["updateDataModel"]["value"]["records"]
    assert is_list(records) and records != [], "surface records must be non-empty"
    assert hd(records)["name"] == seeded.business_unit.name
  end
end
