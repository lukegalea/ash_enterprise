defmodule AshEnterprise.Channels.BlockedReasonTest do
  @moduledoc """
  Why an act does not go ahead, the same on the web and over ACP (R2 HW-07, AGT-54).

  The synthetic clinic's credential activation (`Credential.activate_credential`, four
  eyes, by the credentialing committee, reaching the registry) is blocked four different
  ways, and each reads as its own reason:

    * a committee member asks to activate one: `forbidden` (the committee reads the
      clinic's records and may not change them);
    * the coordinator asks: `pending`, `approval_required`;
    * a committee member rejects it: `policy_failed`;
    * a committee member approves it while the registry is down: `integration_unavailable`.

  The first two are acts on the credentials surface, made through both channels: the
  web's action path (`AshEnterpriseWeb.A2ui.Host.act/3`, which writes `/ui/feedback`) and
  ACP's `_a2ui/action` through a real `AshAcp.Server` session. Their result and reason
  are the same. The last two happen after the request, so they are read from the
  invocation the request became, by the one function both channels use.

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  require Ash.Query

  alias AshAcp.Server
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Channels
  alias AshEnterprise.Credentialing.{DemoData, Registry}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Actions.ConfirmInvocation
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.{CredentialUI, Host}

  @moduletag evidence: true

  setup do
    original = Application.get_all_env(:ash_acp)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end) end)
    on_exit(fn -> Application.delete_env(:ash_enterprise, :acp_operator_email) end)

    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    Oban.drain_queue(queue: :execution)

    # A credential nobody has asked about yet.
    asked = MapSet.new(clinic.requests, &subject_id/1)

    [credential | _] =
      Enum.filter(clinic.credentials, &(&1.status == :pending and &1.id not in asked))

    %{tenant: admin.tenant, clinic: clinic, credential: credential}
  end

  defp person(user, tenant),
    do: [
      actor: ActorContext.attach(user, ActorContext.build(user, tenant: tenant)),
      tenant: tenant
    ]

  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp envelope(credential, :request) do
    %{
      "name" => "invoke",
      "context" => %{
        "action" => "request_activation",
        "recordId" => credential.id,
        "component" => "table"
      }
    }
  end

  # The credential's edit form: `correct`, a change to its number.
  defp envelope(credential, :correct) do
    %{
      "name" => "submit_form",
      "context" => %{
        "recordId" => credential.id,
        "values" => %{"number" => "SYN-#{System.unique_integer([:positive])}"}
      }
    }
  end

  # The web: the surface's action path, as the page runs it.
  defp web(user, credential, tenant, act \\ :request) do
    {_status, messages} = Host.act(CredentialUI, envelope(credential, act), person(user, tenant))

    feedback =
      Enum.find_value(messages, fn
        %{"updateDataModel" => %{"path" => "/ui/feedback", "value" => value}} -> value
        _other -> nil
      end)

    {Channels.from_feedback(feedback), feedback && feedback["blockedReason"]}
  end

  # ACP: `_a2ui/action` on the same surface, through a real session as the person.
  defp acp(user, credential, act \\ :request) do
    Application.put_env(:ash_enterprise, :acp_operator_email, to_string(user.email))

    {_init, _, state} =
      rpc(Server.new(AshAcp.config()), "initialize", %{"protocolVersion" => 1})

    {resp, _updates, state} = rpc(state, "session/new", %{"cwd" => "/tmp"})
    sid = resp["result"]["sessionId"]

    {resp, updates, state} =
      rpc(state, "_a2ui/action", %{
        "sessionId" => sid,
        "surfaceId" => "credentials",
        "action" => envelope(credential, act)
      })

    {resp, _updates, _state, _asked} = answer_permissions(resp, updates, state)
    answer = resp["result"]
    {Channels.from_acp(answer), answer["blockedReason"]}
  end

  # Allows the permission request an act that asks first sends, as the person would.
  defp answer_permissions(resp, updates, state, asked \\ 0)

  defp answer_permissions(nil, updates, state, asked) when asked < 3 do
    case Enum.find(updates, &(&1["method"] == "session/request_permission")) do
      %{"id" => id} ->
        {next, more, state} =
          Server.handle_message(
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
            },
            state
          )

        answer_permissions(next, more, state, asked + 1)

      nil ->
        {nil, updates, state, asked}
    end
  end

  defp answer_permissions(resp, updates, state, asked), do: {resp, updates, state, asked}

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

  defp activation(credential, tenant) do
    target = "AshEnterprise.Credentialing.Credential.activate_credential"

    Execution.Invocation
    |> Ash.Query.filter(target == ^target)
    |> Ash.read!(oban(tenant))
    |> Enum.find(&(subject_id(&1) == credential.id))
  end

  # The credential a request is about, as its preconditions bind it.
  defp subject_id(%{preconditions: [%{"id" => id} | _]}), do: id
  defp subject_id(_row), do: nil

  defp decide(row, member, action, tenant) do
    key = Approval.key()
    id = row.id

    task =
      HumanTask
      |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: task.id}, person(member, tenant))
    |> Ash.run_action!()

    Execution.apply_invocation_decision!(row, oban(tenant))
  end

  test "a committee member may not change a credential: forbidden, on both channels", ctx do
    [member | _] = ctx.clinic.committee

    assert web(member, ctx.credential, ctx.tenant, :correct) == {:forbidden, "forbidden"}
    assert acp(member, ctx.credential, :correct) == {:forbidden, "forbidden"}
  end

  test "a committee member's own request waits like any other, and runs without the authority to act: forbidden",
       ctx do
    [member, other] = Enum.take(ctx.clinic.committee, 2)

    assert web(member, ctx.credential, ctx.tenant) == {:pending, "approval_required"}
    assert acp(member, ctx.credential) == {:pending, "approval_required"}

    row = activation(ctx.credential, ctx.tenant)
    assert decide(row, other, :approve, ctx.tenant).status == :ready
    Oban.drain_queue(queue: :execution)

    refused = Execution.get_invocation!(row.id, oban(ctx.tenant))
    assert refused.status == :failed
    assert Channels.blocked_reason(refused) == :forbidden
  end

  test "the coordinator asks: pending on approval, on both channels; then a rejection and an unreachable registry",
       ctx do
    coordinator = ctx.clinic.coordinator
    [member | _] = ctx.clinic.committee

    assert web(coordinator, ctx.credential, ctx.tenant) == {:pending, "approval_required"}

    row = activation(ctx.credential, ctx.tenant)
    assert row.status == :awaiting_approval
    assert Channels.blocked_reason(row) == :approval_required

    # The same act over ACP is the same request (its key), and reads the same.
    assert acp(coordinator, ctx.credential) == {:pending, "approval_required"}
    assert activation(ctx.credential, ctx.tenant).id == row.id

    # Rejected by the committee: a decision refused it.
    rejected = decide(row, member, :reject, ctx.tenant)
    assert rejected.status == :rejected
    assert Channels.blocked_reason(rejected) == :policy_failed
  end

  test "approved while the registry is down: integration_unavailable", ctx do
    coordinator = ctx.clinic.coordinator
    [member | _] = ctx.clinic.committee

    assert web(coordinator, ctx.credential, ctx.tenant) == {:pending, "approval_required"}
    row = activation(ctx.credential, ctx.tenant)
    assert decide(row, member, :approve, ctx.tenant).status == :ready

    :ok = Supervisor.terminate_child(AshEnterprise.Supervisor, Registry)
    on_exit(fn -> Supervisor.restart_child(AshEnterprise.Supervisor, Registry) end)

    Oban.drain_queue(queue: :execution)

    waiting = Execution.get_invocation!(row.id, oban(ctx.tenant))
    assert waiting.failure_class == :transient
    assert waiting.status in [:ready, :failed]
    assert Channels.blocked_reason(waiting) == :integration_unavailable
  end

  test "the four reasons are distinct, and nothing unrecognised reads as unblocked" do
    reasons = [
      Channels.blocked_reason(:forbidden),
      Channels.blocked_reason(%{status: :awaiting_approval}),
      Channels.blocked_reason(%{status: :rejected}),
      Channels.blocked_reason(%{status: :outcome_unknown})
    ]

    assert reasons == Channels.blocked_reasons()
    assert reasons |> Enum.uniq() |> length() == 4

    for unknown <- [nil, %{}, %{status: nil}, %{status: :exploded}, "ready", :maybe] do
      assert Channels.blocked_reason(unknown) == :unclassified, inspect(unknown)
    end

    assert Channels.blocked_reason(%{status: :request_info}) == :approval_required
    assert Channels.blocked_reason(%{status: :stale}) == :approval_required
    assert Channels.blocked_reason(%{status: :failed, failure_class: :denied}) == :forbidden
    assert Channels.blocked_reason(%{status: :failed, failure_class: :business}) == :policy_failed

    assert Channels.blocked_reason(%{status: :failed, failure_class: :permanent}) ==
             :unclassified
  end

  test "no channel answer the vocabulary does not know reads as applied or pending" do
    for answer <- [nil, %{}, %{"outcome" => "maybe"}, %{"result" => "done"}, %{"outcome" => nil}] do
      assert Channels.from_acp(answer) == :failed, inspect(answer)
      assert Channels.from_feedback(answer) == :failed, inspect(answer)
    end

    assert Channels.result(:exploded, {HumanTask, :approve}) == :failed
    assert Channels.result({:error, []}, {HumanTask, :approve}) == :failed
    assert Channels.result({:error, :not_a_list}, {HumanTask, :approve}) == :failed
    assert Channels.result({:ok, []}, {HumanTask, :approve}) == :applied

    # A request door that answers with no request it recognises is not pending.
    door = {AshEnterprise.Credentialing.Credential, :request_activation}

    for messages <- [[], [answer(%{})], [answer(%{"status" => "sideways"})], [answer(nil)]] do
      assert Channels.outcome({:ok, messages}, door) == {:failed, :unclassified},
             inspect(messages)
    end
  end

  defp answer(row),
    do: %{"updateDataModel" => %{"path" => "/ui/action_result", "value" => row}}

  defp response(row),
    do: %{"updateDataModel" => %{"path" => "/ui/response", "value" => %{"result" => row}}}

  test "a request door answers with what its request came to, not that it waits" do
    confirm = {AshEnterprise.SystemOne.CalibrationRun, :certify_now}
    request = {AshEnterprise.Credentialing.Credential, :request_activation}

    for door <- [confirm, request], wrap <- [&answer/1, &response/1] do
      outcome = &Channels.outcome({:ok, [wrap.(&1)]}, door)

      # Confirmed and run at once, or a keyed door's row that already ran: done.
      assert outcome.(%{"status" => "succeeded"}) == {:applied, :none}
      assert outcome.(%{"status" => "awaiting_approval"}) == {:pending, :approval_required}
      assert outcome.(%{"status" => "request_info"}) == {:pending, :approval_required}
      assert outcome.(%{"status" => "ready"}) == {:pending, :none}
      assert outcome.(%{"status" => "rejected"}) == {:failed, :policy_failed}
      assert outcome.(%{"status" => "outcome_unknown"}) == {:pending, :integration_unavailable}

      assert outcome.(%{"status" => "ready", "failure_class" => "transient"}) ==
               {:pending, :integration_unavailable}

      assert outcome.(%{"status" => "failed", "failure_class" => "timeout"}) ==
               {:failed, :integration_unavailable}

      assert outcome.(%{"status" => "failed", "failure_class" => "business"}) ==
               {:failed, :policy_failed}

      assert outcome.(%{"status" => "failed", "failure_class" => "denied"}) ==
               {:failed, :forbidden}

      assert outcome.(%{"status" => "stale"}) == {:failed, :approval_required}

      assert outcome.(%{"status" => "failed", "failure_class" => "nonsense"}) ==
               {:failed, :unclassified}
    end

    assert Channels.result({:ok, [answer(%{"status" => "succeeded"})]}, confirm) == :applied
  end

  # A click that ran and did not succeed answers with its row, as one that did, so the
  # channels read why from the row's status rather than from an error they cannot place.
  for {status, failure_class, code, expected} <- [
        {:failed, :business, "unpublished_draft_exists", {:failed, :policy_failed}},
        {:failed, :denied, nil, {:failed, :forbidden}},
        {:rejected, nil, nil, {:failed, :policy_failed}},
        {:stale, nil, "manifest_changed", {:failed, :approval_required}}
      ] do
    test "a confirmed click whose request is #{status} #{failure_class} is classified by it" do
      row = %Execution.Invocation{
        id: Ash.UUID.generate(),
        target: "AshEnterprise.SystemOne.CalibrationRun.certify_and_publish",
        status: unquote(status),
        failure_class: unquote(failure_class),
        error_code: unquote(code)
      }

      assert {:ok, %{"status" => status} = reported} = ConfirmInvocation.report(row)
      assert status == unquote(Atom.to_string(status))

      for wrap <- [&answer/1, &response/1] do
        assert Channels.outcome(
                 {:ok, [wrap.(reported)]},
                 {AshEnterprise.SystemOne.CalibrationRun, :certify_now}
               ) == unquote(expected)
      end
    end
  end
end
