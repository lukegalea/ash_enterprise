defmodule AshEnterprise.AcpActionItemsTest do
  @moduledoc """
  Action items over ACP (PROD-18), through the real `AshAcp.Server`, as a
  member with no role grant: `todo <text>` captures into their Inbox with the
  text as typed, `todo` lists their open items numbered, `done N` finishes
  the Nth, and each turn closes with the Action items surface. A number that
  is not on their list is refused.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshAcp.Server
  alias AshEnterprise.Canonical.Task

  setup do
    original = Application.get_all_env(:ash_acp)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end) end)
    on_exit(fn -> Application.delete_env(:ash_enterprise, :acp_operator_email) end)

    admin = tenant!()
    %{me: member!(admin, "Nobody special", [])}
  end

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
        Server.new(AshAcp.config())
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

  defp surface_id([%{"createSurface" => %{"surfaceId" => id}}]), do: id
  defp surface_id(_other), do: nil

  test "todo captures as typed, todo lists, done N finishes", %{me: me} do
    s = session(me)

    captured = prompt(s, "todo Send Dana the Q3 deck")
    assert captured.response["result"]["stopReason"] == "end_turn"
    assert captured.permission == nil
    assert captured.said =~ "Captured into your Inbox: Send Dana the Q3 deck"
    assert surface_id(captured.surface) == "action_items"

    _second = prompt(s, "todo Book the venue")

    assert [_, _] = tasks = Task.mine!(actor: me.actor, tenant: me.tenant)
    assert Enum.all?(tasks, &(&1.source == "acp" and &1.plan == :inbox and &1.status == :open))

    listed = prompt(s, "todo")
    assert listed.said =~ "Action items — 2 open."
    # Newest first within a lane, as on the board.
    assert listed.said =~ "1. Book the venue"
    assert listed.said =~ "2. Send Dana the Q3 deck"
    assert surface_id(listed.surface) == "action_items"
    assert "todo" in listed.commands
    assert "done" in listed.commands

    finished = prompt(s, "done 2")
    assert finished.response["result"]["stopReason"] == "end_turn"
    assert finished.said =~ "Done: Send Dana the Q3 deck"

    assert prompt(s, "todo").said =~ "1. Book the venue"
    refute prompt(s, "todo").said =~ "Send Dana"

    refused = prompt(s, "done 7")
    assert refused.response["result"]["stopReason"] == "refusal"

    assert [%Task{title: "Book the venue"}] =
             Task.mine!(actor: me.actor, tenant: me.tenant, query: [filter: [status: :open]])
  end

  test "another member's items are not on their list", %{me: me} do
    other = member!(me, "Colleague", [])
    Task.capture!("Their private errand", %{}, actor: other.actor, tenant: other.tenant)

    turn = prompt(session(me), "todo")
    assert turn.said =~ "nothing open"
    refute turn.said =~ "Their private errand"
    assert prompt(session(me), "done 1").response["result"]["stopReason"] == "refusal"
  end
end
