defmodule AshEnterprise.AcpDailyTest do
  @moduledoc """
  The daily loop over ACP (`AshEnterprise.Acp.Commands`), through the real
  `AshAcp.Server` and the host seams: each prompt answers with its text and
  closes the turn with the same A2UI surface the web page serves; the command
  palette is pruned per actor; an empty, zone-gated inbox says why; decisions
  wait on a permission request; and shred is not reachable at all.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshAcp.Server
  alias AshEnterprise.Acp

  setup do
    original = Application.get_all_env(:ash_acp)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end) end)
    on_exit(fn -> Application.delete_env(:ash_enterprise, :acp_operator_email) end)
    :ok
  end

  # A session for `ctx`'s user, as `scripts/acp-attach` opens one.
  defp session(ctx) do
    Application.put_env(:ash_enterprise, :acp_operator_email, ctx.email)

    {_, _, state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => 1}
        },
        Server.new(Acp.server_config())
      )

    {resp, _, state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "session/new",
          "params" => %{"cwd" => "/tmp"}
        },
        state
      )

    {resp["result"]["sessionId"], state}
  end

  defp prompt({sid, state}, text) do
    {resp, updates, state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => System.unique_integer([:positive]),
          "method" => "session/prompt",
          "params" => %{"sessionId" => sid, "prompt" => [%{"type" => "text", "text" => text}]}
        },
        state
      )

    said =
      for %{"method" => "session/update", "params" => %{"update" => update}} <- updates,
          update["sessionUpdate"] == "agent_message_chunk",
          into: "",
          do: update["content"]["text"]

    closing =
      Enum.find_value(updates, fn
        %{"params" => %{"update" => %{"sessionUpdate" => "available_commands_update"} = u}} -> u
        _ -> nil
      end)

    %{
      response: resp,
      said: said,
      surface: closing && get_in(closing, ["_meta", "a2ui"]),
      commands: closing && Enum.map(closing["availableCommands"], & &1["name"]),
      permission: Enum.find(updates, &(&1["method"] == "session/request_permission")),
      state: {sid, state}
    }
  end

  defp components(surface) do
    for %{"createSurface" => %{"components" => components}} <- surface,
        component <- components,
        do: component
  end

  test "each daily prompt answers in text and closes with its A2UI surface" do
    ctx = tenant!(operator?: true)
    event!(ctx, "Synthetic planning", 5, 30)
    s = session(ctx)

    for {text, surface_id, grid?} <- [
          {"today", "today", true},
          {"calendar", "calendar", true},
          {"calendar tomorrow", "calendar", true},
          {"inbox", "inbox", true},
          {"slack", "slack", true},
          {"people", "people", true},
          {"approvals", "approvals", true},
          {"accounts", "accounts", true},
          {"erasure", "erasure_scopes_read_only", true}
        ] do
      turn = prompt(s, text)

      assert turn.response["result"]["stopReason"] == "end_turn", text
      assert turn.said != "", text
      assert [%{"version" => "v1.0", "createSurface" => create}] = turn.surface, text
      assert create["surfaceId"] == surface_id, text
      assert Map.has_key?(create, "dataModel"), text

      if grid? do
        assert Enum.any?(components(turn.surface), &(&1["component"] == "dataGrid")), text
      end
    end

    assert prompt(s, "calendar").said =~ "Synthetic planning"
  end

  test "help and the palette list only what the actor may run" do
    operator = tenant!(operator?: true)
    admin = tenant!()

    operator_turn = prompt(session(operator), "help")
    assert "erasure" in operator_turn.commands
    assert operator_turn.said =~ "erasure"

    admin_turn = prompt(session(admin), "help")
    refute "erasure" in admin_turn.commands
    refute admin_turn.said =~ "erasure"
    assert "today" in admin_turn.commands
  end

  test "a non-operator's erasure prompt is refused, not answered" do
    admin = tenant!()
    turn = prompt(session(admin), "erasure")

    # Policy refuses the read; ash_acp turns that into a permission request,
    # and approving one never bypasses the policy that refused it.
    assert turn.permission || turn.response["error"] ||
             turn.response["result"]["stopReason"] == "refusal"

    refute turn.said =~ "Erasure scopes —"
  end

  test "shred is not reachable over ACP" do
    ctx = tenant!(operator?: true)
    s = session(ctx)

    assert prompt(s, "shred connection:anything").response["result"]["stopReason"] == "refusal"

    turn = prompt(s, "erasure")
    encoded = JSON.encode!(turn.surface)
    refute encoded =~ ~s("shred")
    # The only row action is opening a scope's detail (context_select): nothing writes.
    row_actions = Enum.flat_map(components(turn.surface), &Map.get(&1, "rowActions", []))
    refute JSON.encode!(row_actions) =~ "shred"
    refute JSON.encode!(row_actions) =~ ~s("invoke")
    refute JSON.encode!(row_actions) =~ ~s("prompt")
  end

  test "a zone-gated, empty inbox says why it is empty" do
    ctx = tenant!()
    turn = prompt(session(ctx), "inbox")

    assert turn.said =~ "Inbox (Gmail) — no conversations."
    assert turn.said =~ "held back until zone admission (ADR 0042)"
    assert JSON.encode!(turn.surface) =~ "emptyState"
  end

  test "approving the brief waits on a permission request, then decides it" do
    ctx = tenant!()
    brief = brief!(ctx)
    s = session(ctx)

    turn = prompt(s, "approve brief")
    assert %{"id" => perm_id, "params" => %{"toolCall" => %{"title" => title}}} = turn.permission
    assert title =~ "Approve: Morning brief"
    assert turn.response == nil, "the turn stays open until the client answers"
    assert %{status: :pending_approval} = reload_brief!(brief, ctx.tenant)

    {sid, state} = turn.state

    {resp, _updates, _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => perm_id,
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
        },
        state
      )

    assert resp["result"]["stopReason"] == "end_turn"
    assert sid
    assert %{status: :approved} = reload_brief!(brief, ctx.tenant)
  end

  test "rejecting at the permission request leaves the task waiting" do
    ctx = tenant!()
    brief = brief!(ctx)

    turn = prompt(session(ctx), "reject 1")
    assert %{"id" => perm_id} = turn.permission
    {_sid, state} = turn.state

    {resp, _updates, _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => perm_id,
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "reject_once"}}
        },
        state
      )

    assert resp["result"]["stopReason"] == "refusal"
    assert %{status: :pending_approval} = reload_brief!(brief, ctx.tenant)
  end
end
