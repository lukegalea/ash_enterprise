defmodule AshEnterpriseWeb.McpAssignRoleTest do
  @moduledoc """
  The `/mcp` `assign_role` tool is governed (ADR 0055): a model calling it records a
  request through `invoke` and gets back where the request waits, and nothing changes
  until an administrator other than the caller approves it. Driven through the MCP
  router, as an MCP client calls it, with a bearer token.
  """

  use AshEnterpriseWeb.ConnCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1, colleague!: 2]

  require Ash.Query

  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.UserRole

  setup do
    ctx = tenant!()
    %{ctx: ctx, approver: colleague!(ctx, admin?: true), newcomer: colleague!(ctx)}
  end

  defp call_tool(conn, user, name, arguments) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{"input" => arguments}}
    })
  end

  defp roles_of(user, tenant) do
    UserRole
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  test "assign_role returns the request and its approval URL, and assigns nothing", %{
    conn: conn,
    ctx: ctx,
    newcomer: newcomer
  } do
    conn =
      call_tool(conn, ctx.user, "assign_role", %{
        "user_id" => newcomer.user.id,
        "role_id" => ctx.role.id
      })

    assert %{"result" => %{"isError" => false, "structuredContent" => result}} =
             json_response(conn, 200)

    assert %{
             "status" => "awaiting_approval",
             "target" => "AshEnterprise.Security.UserRole.assign_governed",
             "error_code" => nil,
             "invocation_id" => id,
             "approval_url" => approval_url
           } = result

    row = Execution.get_invocation!(id, actor: SystemActor.oban(), tenant: ctx.tenant)
    assert row.executing_principal == %{type: :person, id: ctx.user.id}
    assert {row.approval_mode, row.effects["approver_role"]} == {:four_eyes, "administrator"}

    task = Ash.load!(row, :approval_task, authorize?: false).approval_task
    assert approval_url == AshEnterpriseWeb.Endpoint.url() <> "/app/r/approvals/#{task.id}"

    # Nothing is assigned, and nothing is queued to run before someone approves.
    assert roles_of(newcomer.user, ctx.tenant) == []
    assert %{success: 0, failure: 0} = Oban.drain_queue(queue: :execution)
    assert roles_of(newcomer.user, ctx.tenant) == []
  end

  test "approved by another administrator, the assignment runs once, as the caller", %{
    conn: conn,
    ctx: ctx,
    approver: approver,
    newcomer: newcomer
  } do
    %{"result" => %{"structuredContent" => %{"invocation_id" => id}}} =
      conn
      |> call_tool(ctx.user, "assign_role", %{
        "user_id" => newcomer.user.id,
        "role_id" => ctx.role.id
      })
      |> json_response(200)

    oban = [actor: SystemActor.oban(), tenant: ctx.tenant]
    row = Execution.get_invocation!(id, oban)
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    decide = fn who ->
      AshEnterprise.Bpmn.HumanTask
      |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
        actor: who.actor,
        tenant: ctx.tenant
      )
      |> Ash.run_action()
    end

    # The caller may not approve their own request.
    assert {:error, _} = decide.(ctx)
    assert {:ok, _} = decide.(approver)

    assert Execution.apply_invocation_decision!(row, oban).status == :ready
    assert %{success: 1} = Oban.drain_queue(queue: :execution)

    assert Execution.get_invocation!(id, oban).status == :succeeded

    assert [%{role_id: role_id, scoping_business_unit_id: unit_id}] =
             roles_of(newcomer.user, ctx.tenant)

    assert {role_id, unit_id} == {ctx.role.id, ctx.business_unit.id}
  end

  test "the tool lists the request's inputs, not the assignment's", %{conn: conn, ctx: ctx} do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(ctx.user)

    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      |> json_response(200)
      |> get_in(["result", "tools"])

    assert %{"inputSchema" => schema, "description" => description} =
             Enum.find(tools, &(&1["name"] == "assign_role"))

    assert description =~ "Nothing changes yet"

    assert Enum.sort(
             Map.keys(schema["properties"]["input"]["properties"] || schema["properties"])
           ) ==
             Enum.sort(~w(role_id scoping_business_unit_id user_id))
  end
end
