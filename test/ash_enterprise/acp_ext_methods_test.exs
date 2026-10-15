defmodule AshEnterprise.AcpExtMethodsTest do
  @moduledoc """
  The `ash` ACP extension methods (`AshEnterprise.Acp.ExtMethods`) through the
  real `AshAcp.Server`, checked by envelope shape: `initialize` advertises them
  with the actor's surfaces; `_ash/surfaces/list` is pruned by doors;
  `_ash/surface/open` opens a surface — a record selected, re-authorized — with
  no model turn, records it for `session/load`, and refuses what the actor may
  not read; `_a2ui/action` runs reads at once and asks before a write; and the
  `open <surface> <id|n>` prompt opens a record too. SYNTHETIC data only.
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

  defp rpc(state, method, params) do
    Server.handle_message(
      %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      },
      state
    )
  end

  # `{initialize result, session id, state}` for `ctx`'s user.
  defp session(ctx) do
    Application.put_env(:ash_enterprise, :acp_operator_email, ctx.email)

    {init, _, state} =
      rpc(Server.new(Acp.server_config()), "initialize", %{"protocolVersion" => 1})

    {resp, _, state} = rpc(state, "session/new", %{"cwd" => "/tmp"})
    {init["result"], resp["result"]["sessionId"], state}
  end

  defp context_value(a2ui, context) do
    Enum.find_value(a2ui, fn
      %{"createSurface" => %{"dataModel" => %{"context" => contexts}}} ->
        get_in(contexts, [context, "value"])

      _other ->
        nil
    end)
  end

  test "initialize advertises the methods and the actor's surfaces" do
    ctx = tenant!()
    {init, _sid, _state} = session(ctx)

    ash = init["agentCapabilities"]["_meta"]["ash"]
    assert ash["extMethods"] == ["_ash/surfaces/list", "_ash/surface/open", "_a2ui/action"]
    assert init["_meta"]["ash"] == ash

    ids = Enum.map(ash["surfaces"], & &1["id"])
    assert "people" in ids
    refute "erasure" in ids, "the erasure door is the platform operator's"

    people = Enum.find(ash["surfaces"], &(&1["id"] == "people"))
    assert %{"title" => "People", "group" => "My day", "records" => true} = people
    assert people["recordScoped"] == false
  end

  test "_ash/surfaces/list is pruned by doors" do
    ctx = tenant!()
    operator = tenant!(operator?: true)

    {_init, sid, state} = session(ctx)
    {resp, [], _state} = rpc(state, "_ash/surfaces/list", %{"sessionId" => sid})
    refute "erasure" in Enum.map(resp["result"]["surfaces"], & &1["id"])

    {_init, sid, state} = session(operator)
    {resp, [], _state} = rpc(state, "_ash/surfaces/list", %{"sessionId" => sid})
    assert "erasure" in Enum.map(resp["result"]["surfaces"], & &1["id"])
  end

  test "_ash/surface/open opens a record selected, records it, and session/load re-emits it" do
    ctx = tenant!()
    ada = person!(ctx, "ada@example.test", "Ada Park")
    {_init, sid, state} = session(ctx)

    {resp, updates, state} =
      rpc(state, "_ash/surface/open", %{
        "sessionId" => sid,
        "surface" => "people",
        "recordId" => ada.id
      })

    assert updates == [], "a direct open is not a prompt turn"
    assert %{"surfaceId" => "people", "a2ui" => a2ui} = resp["result"]
    assert context_value(a2ui, "person") == ada.id

    {:ok, session} = Acp.SessionStore.load(sid)
    assert {:agent, "opened People"} in session.transcript

    {resp, replay, _state} = rpc(state, "session/load", %{"sessionId" => sid, "cwd" => "/tmp"})
    assert resp["result"] == %{}

    reemitted =
      Enum.find_value(replay, fn
        %{"params" => %{"update" => %{"sessionUpdate" => "available_commands_update"} = u}} ->
          get_in(u, ["_meta", "a2ui"])

        _other ->
          nil
      end)

    assert context_value(reemitted, "person") == ada.id
  end

  test "_ash/surface/open refuses what the actor may not read" do
    ctx = tenant!()
    other = tenant!()
    theirs = person!(other, "theirs@example.test", "Not Yours")
    {_init, sid, state} = session(ctx)

    {resp, [], _} =
      rpc(state, "_ash/surface/open", %{
        "sessionId" => sid,
        "surface" => "people",
        "recordId" => theirs.id
      })

    assert %{"code" => -32_002, "message" => message} = resp["error"]
    assert message =~ "not found, or it is not yours"

    {resp, [], _} =
      rpc(state, "_ash/surface/open", %{"sessionId" => sid, "surface" => "erasure"})

    assert resp["error"]["code"] == -32_002

    {resp, [], _} = rpc(state, "_ash/surface/open", %{"sessionId" => sid, "surface" => "nope"})
    assert resp["error"]["code"] == -32_602
  end

  test "_a2ui/action runs a read at once" do
    ctx = tenant!()
    ada = person!(ctx, "ada@example.test", "Ada Park")
    {_init, sid, state} = session(ctx)

    {resp, [], _state} =
      rpc(state, "_a2ui/action", %{
        "sessionId" => sid,
        "surfaceId" => "people",
        "action" => %{
          "name" => "context_select",
          "context" => %{"context" => "person", "value" => ada.id}
        }
      })

    assert %{"outcome" => "applied", "a2ui" => a2ui} = resp["result"]

    assert Enum.any?(a2ui, fn message ->
             match?(%{"updateDataModel" => %{"path" => "/context"}}, message)
           end)
  end

  test "_a2ui/action asks before a write, then applies it as the actor" do
    ctx = tenant!()
    brief = brief!(ctx)
    {_init, sid, state} = session(ctx)

    approve = %{
      "sessionId" => sid,
      "surfaceId" => "today",
      "action" => %{
        "name" => "invoke",
        "context" => %{"action" => "approve", "recordId" => brief.id, "component" => "brief"}
      }
    }

    {nil, [permission], state} = rpc(state, "_a2ui/action", approve)
    assert permission["method"] == "session/request_permission"
    assert permission["params"]["toolCall"]["title"] == "Approve · Today"
    assert %{status: :pending_approval} = reload_brief!(brief, ctx.tenant)

    {resp, _settled, _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => permission["id"],
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
        },
        state
      )

    assert resp["result"]["outcome"] == "applied"
    assert %{status: :approved} = reload_brief!(brief, ctx.tenant)
  end

  test "_a2ui/action reports a declined write as denied" do
    ctx = tenant!()
    brief = brief!(ctx)
    {_init, sid, state} = session(ctx)

    {nil, [permission], state} =
      rpc(state, "_a2ui/action", %{
        "sessionId" => sid,
        "surfaceId" => "today",
        "action" => %{
          "name" => "invoke",
          "context" => %{"action" => "reject", "recordId" => brief.id, "component" => "brief"}
        }
      })

    {resp, _settled, _state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => permission["id"],
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "reject_once"}}
        },
        state
      )

    assert resp["result"] == %{"outcome" => "denied", "a2ui" => []}
    assert %{status: :pending_approval} = reload_brief!(brief, ctx.tenant)
  end

  test "the `open <surface> <id|n>` prompt opens a record" do
    ctx = tenant!()
    ada = person!(ctx, "ada@example.test", "Ada Park")
    {_init, sid, state} = session(ctx)

    for text <- ["open people #{ada.id}", "open people 1"] do
      {resp, updates, _state} =
        rpc(state, "session/prompt", %{
          "sessionId" => sid,
          "prompt" => [%{"type" => "text", "text" => text}]
        })

      assert resp["result"]["stopReason"] == "end_turn", text

      surface =
        Enum.find_value(updates, fn
          %{"params" => %{"update" => %{"sessionUpdate" => "available_commands_update"} = u}} ->
            get_in(u, ["_meta", "a2ui"])

          _other ->
            nil
        end)

      assert context_value(surface, "person") == ada.id, text
    end
  end
end
