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
  - An approved action that policy then refuses ends the turn as a refusal,
    rather than wedging the session on a second permission request.

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  require Ash.Query

  alias AshAcp.Server
  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Acp
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security

  setup do
    original = Application.get_all_env(:ash_acp)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end) end)
    on_exit(fn -> Application.delete_env(:ash_enterprise, :acp_operator_email) end)

    admin = tenant!()

    member =
      user!(admin, "Daily member", [
        {AshEnterprise.Agents.MorningBrief, :read, :basic},
        {AshEnterprise.Agents.MorningBrief, :create, :basic},
        {AshEnterprise.Agents.MorningBrief, :write, :basic},
        {HumanTask, :read, :global},
        {AshEnterprise.Bpmn.TaskCandidate, :read, :global},
        {AshEnterprise.Canonical.CalendarEvent, :read, :basic}
      ])

    nobody = user!(admin, "No access", [])

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
    # Composing is a generic action, which a :basic grant does not reach;
    # syncing needs a linked-account grant: neither is held.
    assert "approve" in member.commands and "reject" in member.commands
    refute "compose" in member.commands
    refute "sync" in member.commands

    refute "erasure" in member.commands

    for command <- ~w(compose approve reject sync erasure) do
      refute command in nobody.commands, command
    end

    assert "today" in nobody.commands and "help" in nobody.commands
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

  test "another user's task cannot be decided, whatever the client answers", ctx do
    brief = brief!(ctx.admin)
    task = open_task!(brief, ctx.admin)
    s = session(ctx.member)

    # Not listed for them, so there is nothing to number or name.
    assert prompt(s, "approve 1", "allow_once").response["result"]["stopReason"] == "refusal"
    assert prompt(s, "approve brief", "allow_once").response["result"]["stopReason"] == "refusal"

    # Named directly by id through the surface action: the write asks first,
    # and allowing it still runs as the member, who is not a candidate.
    {resp, _updates, _state} =
      ext_with_permission(s, "_a2ui/action", %{
        "surfaceId" => "approvals",
        "action" => %{
          "name" => "invoke",
          "context" => %{"action" => "approve", "recordId" => task.id, "component" => "tasks"}
        }
      })

    assert JSON.encode!(resp) =~ "UNAUTHORIZED"
    assert %{status: :pending_approval} = reload_brief!(brief, ctx.admin.tenant)
    assert %{status: :open} = Ash.get!(HumanTask, task.id, authorize?: false)
  end

  test "an approved action that policy refuses ends the turn and frees the session", ctx do
    s = session(ctx.nobody)

    # Composing is consequential, so it asks; allowing it runs as a user
    # holding no grant on briefs, whom policy refuses. ash_acp then asks again
    # about the refusal, which approving cannot overturn.
    turn = prompt(s, "compose brief", "allow_once")
    assert turn.response["result"]["stopReason"] == "refusal"
    assert turn.permissions >= 1

    refute Ash.exists?(AshEnterprise.Agents.MorningBrief,
             authorize?: false,
             tenant: ctx.nobody.tenant
           )

    # The session is not wedged on an open turn.
    assert prompt(turn.state, "help").response["result"]["stopReason"] == "end_turn"
  end

  # -- helpers ------------------------------------------------------------------

  # A user in `admin`'s tenant and root business unit with one role granting
  # exactly `grants` (`{resource, verb, depth}`).
  defp user!(admin, role_name, grants) do
    actor = SystemActor.seed()
    tenant = admin.tenant
    unit_id = admin.user.owning_business_unit_id

    role =
      Security.Role
      |> Ash.Changeset.for_create(
        :create,
        %{name: role_name, owning_business_unit_id: unit_id},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()

    for {resource, verb, depth} <- grants do
      name = inspect(resource)

      privilege =
        Security.Privilege
        |> Ash.Query.filter(resource_name == ^name and access_right == ^verb)
        |> Ash.read_one!(authorize?: false)

      Security.RolePrivilege
      |> Ash.Changeset.for_create(
        :create,
        %{role_id: role.id, privilege_id: privilege.id, depth: depth},
        actor: actor,
        tenant: tenant
      )
      |> Ash.create!()
    end

    email = "low-#{System.unique_integer([:positive])}@example.test"

    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: "password1234", password_confirmation: "password1234"},
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:assign_to_business_unit, %{owning_business_unit_id: unit_id},
        authorize?: false
      )
      |> Ash.update!()

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: unit_id},
      actor: actor,
      tenant: tenant
    )
    |> Ash.create!()

    %{actor: actor(user), user: user, tenant: tenant, email: email}
  end

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
      rpc(Server.new(Acp.server_config()), "initialize", %{"protocolVersion" => 1})

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
    {resp, updates, state, _asked} = answer_permissions(resp, updates, state, "allow_once", [])
    {resp, updates, state}
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
