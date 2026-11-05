defmodule AshEnterprise.Acp.CaseApprovalDurableTest do
  @moduledoc """
  Showcase slice 3, the last beat: a committee member approves a credentialing case's
  task over ACP, the application restarts (the session store, where sessions live, is
  emptied), and the approval is still waiting. A client that connects again and sends the
  same request finds the same invocation, and allowing it completes the case's task, so
  the case moves on to its re-credentialing timer.

  The mechanism is `AshEnterprise.Acp.Approvals`' (a permission request is an invocation);
  this is the beat on a real case, through the real `AshAcp.Server`. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshAcp.Server
  alias AshEnterprise.Acp.SessionStore
  alias AshEnterprise.Bpmn.Actions.QueueDigest
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Case, as: Tour

  @target "AshEnterprise.Bpmn.HumanTask.approve"

  setup do
    original = Application.get_all_env(:ash_acp)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end) end)
    on_exit(fn -> Application.delete_env(:ash_enterprise, :acp_operator_email) end)

    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    coordinator = actor(clinic.coordinator, admin.tenant)

    # A credential whose documents are filed: both checks pass and the committee's task opens.
    [credential | _] = clinic.credentials
    Credentialing.open_case!(credential.id, actor: coordinator, tenant: admin.tenant)

    member = hd(clinic.committee)
    %{tenant: admin.tenant, member: member, credential: credential, coordinator: coordinator}
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  # The number `approve N` gives the case's task in this member's list.
  defp number_of_case_task(ctx) do
    task_id = the_case(ctx).review.id
    {:ok, tasks} = QueueDigest.awaiting(actor: actor(ctx.member, ctx.tenant), tenant: ctx.tenant)
    Enum.find_index(tasks, &(&1.id == task_id)) + 1
  end

  defp the_case(ctx) do
    ctx.coordinator
    |> Tour.cases()
    |> Enum.find(&(&1.credential.id == ctx.credential.id))
  end

  test "an approval over ACP survives a restart, and allowing it moves the case on", ctx do
    assert %{review: %{status: :open}} = the_case(ctx)
    n = number_of_case_task(ctx)

    %{sid: sid, permission: %{"params" => %{"_meta" => %{"requestRef" => ref}}}} =
      ctx.member |> session() |> prompt("approve #{n}")

    assert [%{id: ^ref, status: :awaiting_approval}] = requests(ctx)

    restart_session_store!()

    # The session is gone; the request, and the case waiting on it, are not.
    assert {:error, _gone} = SessionStore.load(sid)
    assert [%{id: ^ref, status: :awaiting_approval}] = requests(ctx)
    assert %{review: %{status: :open}, timer: nil} = the_case(ctx)

    # A client that connects again and sends the same request finds it.
    %{state: state, permission: %{"id" => perm_id, "params" => params}} =
      ctx.member |> session() |> prompt("approve #{n}")

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

    # The case's task was decided by the member, and the case waits for its date.
    assert %{review: %{status: :completed}, timer: %{due_at: %DateTime{}}} = the_case(ctx)

    assert %{status: :completed, decided_by_id: decider} =
             HumanTask |> Ash.get!(the_case(ctx).review.id, authorize?: false, tenant: ctx.tenant)

    assert decider == ctx.member.id
  end

  # -- helpers ------------------------------------------------------------------

  # Empties the ETS the sessions live in, as a deploy or a crash does.
  defp restart_session_store! do
    :ok = Supervisor.terminate_child(AshEnterprise.Supervisor, AshEnterprise.Acp.Store)
    {:ok, _pid} = Supervisor.restart_child(AshEnterprise.Supervisor, AshEnterprise.Acp.Store)
  end

  defp requests(ctx) do
    Invocation
    |> Ash.Query.filter(owner_id == ^ctx.member.id and target == @target)
    |> Ash.read!(authorize?: false, tenant: ctx.tenant)
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

  defp session(member) do
    Application.put_env(:ash_enterprise, :acp_operator_email, to_string(member.email))
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
