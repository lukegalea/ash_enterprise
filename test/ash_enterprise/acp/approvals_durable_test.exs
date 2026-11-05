defmodule AshEnterprise.Acp.ApprovalsDurableTest do
  @moduledoc """
  A prompt's permission request is an invocation (ADR 0055,
  `AshEnterprise.Acp.Approvals`): it outlives the session store that held the
  session, and a client that reconnects and sends the same request again finds
  it instead of making a second.

  Through the real `AshAcp.Server`, as `scripts/acp-attach` drives it. SYNTHETIC
  data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  require Ash.Query

  alias AshAcp.Server
  alias AshEnterprise.Acp.{Approvals, SessionStore}
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.SystemActor

  @target "AshEnterprise.Bpmn.HumanTask.approve"

  setup do
    original = Application.get_all_env(:ash_acp)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end) end)
    on_exit(fn -> Application.delete_env(:ash_enterprise, :acp_operator_email) end)

    ctx = tenant!()
    %{ctx: ctx, brief: brief!(ctx)}
  end

  test "a pending approval survives a session-store restart", %{ctx: ctx, brief: brief} do
    %{sid: sid, permission: %{"params" => params}} = session(ctx) |> prompt("approve brief")
    assert params["_meta"]["requestRef"] == only_request!(ctx).id

    restart_session_store!()

    assert {:error, _gone} = SessionStore.load(sid)
    assert %{status: :awaiting_approval} = row = only_request!(ctx)
    assert %{approval_task: %{status: :open}} = Ash.load!(row, :approval_task, authorize?: false)
    assert %{status: :pending_approval} = reload_brief!(brief, ctx.tenant)
  end

  test "a reconnecting client re-sending the same request creates no second invocation",
       %{ctx: ctx, brief: brief} do
    %{permission: %{"params" => %{"_meta" => %{"requestRef" => ref}}}} =
      session(ctx) |> prompt("approve brief")

    restart_session_store!()

    # A new connection, a new session, the same request.
    %{state: state, permission: %{"id" => perm_id, "params" => params}} =
      session(ctx) |> prompt("approve brief")

    assert params["_meta"]["requestRef"] == ref
    assert [%{id: ^ref}] = requests(ctx)

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
    assert [%{id: ^ref, status: :succeeded}] = requests(ctx)
    assert %{status: :approved} = reload_brief!(brief, ctx.tenant)
  end

  test "a different request gets a key of its own", %{ctx: ctx} do
    %{permission: %{"params" => %{"_meta" => %{"requestRef" => ref}}}} =
      session(ctx) |> prompt("approve brief")

    waiting = only_request!(ctx)
    %{args: args} = Ash.load!(waiting, [:args], actor: SystemActor.oban(), tenant: ctx.tenant)
    other = %{"record_id" => Ash.UUID.generate()}

    assert Approvals.key(ctx.actor, @target, args, ctx.tenant) == waiting.invocation_key
    refute Approvals.key(ctx.actor, @target, other, ctx.tenant) == waiting.invocation_key

    # Asking changed nothing.
    assert [%{id: ^ref}] = requests(ctx)
  end

  # -- helpers ------------------------------------------------------------------

  # Empties the ETS the sessions live in, as a deploy or a crash does.
  defp restart_session_store! do
    :ok = Supervisor.terminate_child(AshEnterprise.Supervisor, AshEnterprise.Acp.Store)
    {:ok, _pid} = Supervisor.restart_child(AshEnterprise.Supervisor, AshEnterprise.Acp.Store)
  end

  defp requests(ctx) do
    Invocation
    |> Ash.Query.filter(owner_id == ^ctx.user.id and target == @target)
    |> Ash.read!(authorize?: false, tenant: ctx.tenant)
  end

  defp only_request!(ctx) do
    [row] = requests(ctx)
    row
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

  defp session(ctx) do
    Application.put_env(:ash_enterprise, :acp_operator_email, ctx.email)
    {_init, _, state} = rpc(Server.new(AshAcp.config()), "initialize", %{"protocolVersion" => 1})
    {resp, _updates, state} = rpc(state, "session/new", %{"cwd" => "/tmp"})
    {resp["result"]["sessionId"], state}
  end

  # One prompt turn, which stops on its permission request.
  defp prompt({sid, state}, text) do
    {nil, updates, state} =
      rpc(state, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => text}]
      })

    %{
      sid: sid,
      state: state,
      permission: Enum.find(updates, &(&1["method"] == "session/request_permission"))
    }
  end
end
