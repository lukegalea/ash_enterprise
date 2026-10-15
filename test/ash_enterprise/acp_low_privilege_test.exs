defmodule AshEnterprise.AcpLowPrivilegeTest do
  @moduledoc """
  ACP as someone who is not an Administrator (epic E3/E5 acceptance): a tenant
  member holding a narrow role, and a user whose role grants nothing, driving
  the real `AshAcp.Server` through the host seams under real policies.

  - The session opens. A `:basic` grant on a palette action's resource used
    to make `Ash.can?/3` raise during pruning (a generic action under a
    filter check), so `session/new` failed for every such user.
  - The palette is pruned per actor: what a role does not allow is not offered.
  - The member decides their own approval through `session/request_permission`
    — rejecting leaves it waiting, allowing decides it.
  - Approving is itself policy-gated: another user's task cannot be decided,
    whatever the client answers.
  - What policy refuses is refused before anyone is asked (ash_acp 0.3); a
    write refused when it runs answers `failed`/`forbidden`, never
    `applied`, and the session is never wedged on a second permission
    request.
  - Composing one's own brief is self-service (ADR 0052): a member holding no
    MorningBrief grant is offered `compose` and composes their own brief; a
    deactivated account is refused.

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshAcp.Server
  alias AshEnterprise.Acp.ExtMethods
  alias AshEnterprise.Bpmn.HumanTask

  setup do
    original = Application.get_all_env(:ash_acp)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end) end)
    on_exit(fn -> Application.delete_env(:ash_enterprise, :acp_operator_email) end)

    admin = tenant!()

    member =
      member!(admin, "Daily member", [
        {AshEnterprise.Agents.MorningBrief, :read, :basic},
        {AshEnterprise.Agents.MorningBrief, :create, :basic},
        {AshEnterprise.Agents.MorningBrief, :write, :basic},
        {HumanTask, :read, :global},
        {AshEnterprise.Bpmn.TaskCandidate, :read, :global},
        {AshEnterprise.Canonical.CalendarEvent, :read, :basic}
      ])

    nobody = member!(admin, "No access", [])

    %{admin: admin, member: member, nobody: nobody}
  end

  test "the session opens and the palette offers only what each role allows", ctx do
    admin = session(ctx.admin)
    member = session(ctx.member)
    nobody = session(ctx.nobody)

    assert admin.commands, "admin session/new: #{inspect(admin.error)}"
    assert member.commands, "member session/new: #{inspect(member.error)}"
    assert nobody.commands, "zero-grant session/new: #{inspect(nobody.error)}"

    assert Enum.all?(~w(compose approve reject sync), &(&1 in admin.commands))

    # Approving needs read on tasks (organization-owned, so :global): held.
    # Syncing needs a linked-account grant: not held. Composing one's own
    # brief is self-service, so it needs no grant at all (ADR 0052).
    assert "approve" in member.commands and "reject" in member.commands
    assert "compose" in member.commands
    refute "sync" in member.commands

    refute "erasure" in member.commands

    for command <- ~w(approve reject sync erasure) do
      refute command in nobody.commands, command
    end

    assert "compose" in nobody.commands
    assert "today" in nobody.commands and "help" in nobody.commands
  end

  test "a member holding no MorningBrief grant composes their own brief", ctx do
    platform_brief_process!()
    on_exit(&AshEnterprise.Process.Resolver.forget_platform_tenant/0)

    s = session(ctx.nobody)

    turn = prompt(s, "compose brief", "allow_once")
    assert turn.permission == "Compose today's brief"
    assert turn.response["result"]["stopReason"] == "end_turn"
    assert turn.said =~ "Composing your morning brief"

    assert [brief] =
             AshEnterprise.Agents.MorningBrief
             |> Ash.read!(authorize?: false, tenant: ctx.nobody.tenant)

    assert brief.owner_id == ctx.nobody.user.id
    assert brief.status == :pending_approval

    # The day has their brief now: `compose brief` shows it instead of asking.
    again = prompt(turn.state, "compose brief")
    assert again.permissions == 0
    assert again.response["result"]["stopReason"] == "end_turn"
  end

  test "the member decides their own approval through the permission round-trip", ctx do
    brief = brief!(ctx.member)
    s = session(ctx.member)

    turn = prompt(s, "approve brief", "reject_once")
    assert turn.permission =~ "Approve: Morning brief"
    assert turn.response["result"]["stopReason"] == "refusal"
    assert %{status: :pending_approval} = reload_brief!(brief, ctx.member.tenant)

    turn = prompt(turn.state, "approve brief", "allow_once")
    assert turn.response["result"]["stopReason"] == "end_turn"
    assert turn.said =~ "Approved"
    assert %{status: :approved} = reload_brief!(brief, ctx.member.tenant)
  end

  test "a row-scoped grant approves the member's own brief through the surface", ctx do
    brief = brief!(ctx.member)
    s = session(ctx.member)

    # The member's MorningBrief grant is :basic — row-scoped. The up-front
    # check judges the brief itself (a blank one would fail every row scope),
    # so the member is asked, and allowing it applies.
    {resp, _updates, _state, asked} =
      ext_with_permission(s, "_a2ui/action", %{
        "surfaceId" => "today",
        "action" => %{
          "name" => "invoke",
          "context" => %{"action" => "approve", "recordId" => brief.id, "component" => "brief"}
        }
      })

    assert asked == ["Approve · Today"]
    assert resp["result"]["outcome"] == "applied"
    assert %{status: :approved} = reload_brief!(brief, ctx.member.tenant)
  end

  test "another user's task cannot be decided, whatever the client answers", ctx do
    brief = brief!(ctx.admin)
    task = open_task!(brief, ctx.admin)
    s = session(ctx.member)

    # Not listed for them, so there is nothing to number or name.
    assert prompt(s, "approve 1", "allow_once").response["result"]["stopReason"] == "refusal"
    assert prompt(s, "approve brief", "allow_once").response["result"]["stopReason"] == "refusal"

    # Named directly by id through the surface action. Who is a candidate is
    # decided by the run, not by a policy, so the write asks first; allowing
    # it still runs as the member, who is refused, and the outcome says so.
    approve = %{
      "surfaceId" => "approvals",
      "action" => %{
        "name" => "invoke",
        "context" => %{"action" => "approve", "recordId" => task.id, "component" => "tasks"}
      }
    }

    {resp, _updates, _state, asked} = ext_with_permission(s, "_a2ui/action", approve)

    assert asked == ["Approve · Approvals"]
    assert %{"outcome" => "failed", "error" => %{"kind" => "forbidden"}} = resp["result"]
    assert %{status: :pending_approval} = reload_brief!(brief, ctx.admin.tenant)
    assert %{status: :open} = Ash.get!(HumanTask, task.id, authorize?: false)
  end

  test "a write policy refuses at execution answers failed, read back from the handler", ctx do
    brief = brief!(ctx.admin)
    task = open_task!(brief, ctx.admin)
    actor = AshEnterprise.Security.ActorContext.for_actor(ctx.member.user)
    actor = AshEnterprise.Security.ActorContext.attach(ctx.member.user, actor)

    # When the up-front check cannot decide, the refusal comes back from
    # AshA2ui.ActionHandler as data-model messages only; the outcome's kind
    # is read from them.
    action = %{
      "name" => "invoke",
      "context" => %{"action" => "approve", "recordId" => task.id, "component" => "tasks"}
    }

    ui = AshEnterprise.Surfaces.acp_ui(AshEnterprise.Surfaces.fetch!(:approvals))

    assert {:error, messages} =
             AshA2ui.ActionHandler.handle(ui, action, actor: actor, tenant: ctx.member.tenant)

    assert ExtMethods.failure_kind(messages) == :forbidden

    status = fn path, value ->
      [%{"updateDataModel" => %{"surfaceId" => "s", "path" => path, "value" => value}}]
    end

    assert ExtMethods.failure_kind(
             status.("/ui/status", "You are not authorized to perform this action.")
           ) == :forbidden

    assert ExtMethods.failure_kind(status.("/errors/title", "is required")) == :invalid
    assert ExtMethods.failure_kind(status.("/ui/status", "Something went wrong.")) == :error
  end

  test "a deactivated account is refused before anyone is asked", ctx do
    platform_brief_process!()
    on_exit(&AshEnterprise.Process.Resolver.forget_platform_tenant/0)

    s = session(deactivate!(ctx.nobody))

    # Self-service does not admit a deactivated account and no grant covers
    # it, so ash_acp's up-front check refuses: no approval, nothing asked.
    turn = prompt(s, "compose brief", "allow_once")
    assert turn.response["result"]["stopReason"] == "refusal"
    assert turn.permissions == 0

    refute Ash.exists?(AshEnterprise.Agents.MorningBrief,
             authorize?: false,
             tenant: ctx.nobody.tenant
           )

    # The session is not wedged on an open turn.
    assert prompt(turn.state, "help").response["result"]["stopReason"] == "end_turn"
  end

  # -- helpers ------------------------------------------------------------------

  defp open_task!(brief, %{actor: actor, tenant: tenant}) do
    {:ok, task} =
      AshEnterprise.Agents.BriefDecision.open_task(brief, actor: actor, tenant: tenant)

    task
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

  # `initialize` + `session/new` as `ctx`'s user, as `scripts/acp-attach` opens one.
  defp session(ctx) do
    Application.put_env(:ash_enterprise, :acp_operator_email, ctx.email)

    {_init, _, state} =
      rpc(Server.new(AshAcp.config()), "initialize", %{"protocolVersion" => 1})

    {resp, updates, state} = rpc(state, "session/new", %{"cwd" => "/tmp"})

    %{
      sid: resp["result"] && resp["result"]["sessionId"],
      state: state,
      error: resp["error"],
      commands: commands(updates)
    }
  end

  defp commands(updates) do
    Enum.find_value(updates, fn
      %{"params" => %{"update" => %{"sessionUpdate" => "available_commands_update"} = u}} ->
        Enum.map(u["availableCommands"], & &1["name"])

      _other ->
        nil
    end)
  end

  # One prompt turn, answering every permission request with `answer`, until
  # the turn's own response arrives.
  defp prompt(%{sid: sid, state: state} = s, text, answer \\ "reject_once") do
    {resp, updates, state} =
      rpc(state, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => text}]
      })

    {resp, updates, state, asked} = answer_permissions(resp, updates, state, answer, [])

    said =
      for %{"method" => "session/update", "params" => %{"update" => update}} <- updates,
          update["sessionUpdate"] == "agent_message_chunk",
          into: "",
          do: update["content"]["text"]

    %{
      response: resp,
      said: said,
      permission: List.first(asked),
      permissions: length(asked),
      state: %{s | state: state}
    }
  end

  defp ext_with_permission(%{sid: sid, state: state}, method, params) do
    {resp, updates, state} = rpc(state, method, Map.put(params, "sessionId", sid))
    answer_permissions(resp, updates, state, "allow_once", [])
  end

  # Answers a pending `session/request_permission` (at most a few, so a loop
  # of re-asks fails the test instead of hanging it).
  defp answer_permissions(resp, updates, state, answer, asked) when length(asked) < 4 do
    case Enum.find(updates, &(&1["method"] == "session/request_permission")) do
      %{"id" => id, "params" => %{"toolCall" => %{"title" => title}}} when is_nil(resp) ->
        {next, more, state} =
          Server.handle_message(
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => answer}}
            },
            state
          )

        answer_permissions(next, more, state, answer, asked ++ [title])

      _none ->
        {resp, updates, state, asked}
    end
  end

  defp answer_permissions(resp, updates, state, _answer, asked),
    do: {resp, updates, state, asked}
end
