defmodule AshEnterprise.Execution.EnableAgentTest do
  @moduledoc """
  Turning an agent declared in code on in a tenant (`enable_from_code`, and
  `mix ash_enterprise.assistant.enable` for the assistant): as far as the publish
  request, never the approval or a start grant, and idempotent when run again.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 2, in_zone!: 0]

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Assistant.Agent
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Security.AgentStartGrant
  alias Mix.Tasks.AshEnterprise.Assistant.Enable

  setup do
    in_zone!()
    on_exit(&Resolver.forget_platform_tenant/0)
    %{ctx: tenant!()}
  end

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]
  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp publish_requests(ctx) do
    target = "AshEnterprise.Execution.AgentVersion.apply_publish"

    Invocation
    |> Ash.Query.filter(target == ^target)
    |> Ash.read!(authorize?: false, tenant: ctx.tenant)
  end

  test "a fresh tenant gets a draft and a request waiting for approval", %{ctx: ctx} do
    assert {:ok, result} = Execution.enable_agent_from_code(Agent, opts(ctx))

    assert %{
             "outcome" => "requested",
             "key" => "assistant",
             "status" => "awaiting_approval",
             "self_approval" => false
           } = result

    assert result["approval_url"] =~ "/app/r/approvals/"

    version = Execution.get_agent_version!(result["version_id"], opts(ctx))
    assert %{status: :draft, organization_id: tenant} = version
    assert tenant == ctx.tenant
    assert {:ok, %{id: baseline_id}} = Resolver.agent_baseline("assistant")
    assert version.baseline_id == baseline_id

    assert [%{id: id, status: :awaiting_approval}] = publish_requests(ctx)
    assert id == result["invocation_id"]

    # Nothing was approved and nobody was given the assistant.
    assert AgentStartGrant |> Ash.read!(authorize?: false, tenant: ctx.tenant) == []
  end

  test "run again, it returns the waiting request instead of asking twice", %{ctx: ctx} do
    {:ok, first} = Execution.enable_agent_from_code(Agent, opts(ctx))
    {:ok, again} = Execution.enable_agent_from_code(Agent, opts(ctx))

    assert again["outcome"] == "already_requested"
    assert again["invocation_id"] == first["invocation_id"]
    assert again["version_id"] == first["version_id"]
    assert again["approval_url"] == first["approval_url"]
    assert length(publish_requests(ctx)) == 1
  end

  test "once published, it is a no-op that says so", %{ctx: ctx} do
    approver = colleague!(ctx, admin?: true)
    {:ok, %{"invocation_id" => id}} = Execution.enable_agent_from_code(Agent, opts(ctx))

    row = Execution.get_invocation!(id, authorize?: false, tenant: ctx.tenant)
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id}, opts(approver))
    |> Ash.run_action!()

    %{status: :ready} = Execution.apply_invocation_decision!(row, oban(ctx.tenant))
    {:ok, :succeeded} = Executor.execute(Invocation, row.id, oban(ctx.tenant))

    assert {:ok, %{"outcome" => "already_published", "version" => 1}} =
             Execution.enable_agent_from_code(Agent, opts(ctx))

    assert length(publish_requests(ctx)) == 1
  end

  describe "mix ash_enterprise.assistant.enable" do
    setup do
      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(shell) end)
    end

    test "prints the approval link, and on a rerun that it is already waiting", %{ctx: ctx} do
      args = ["--org", ctx.organization.unique_name, "--as", to_string(ctx.user.email)]

      Enable.run(args)
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "Asked to publish the assistant (version 1)"
      assert message =~ "/app/r/approvals/"
      assert message =~ "other than the requester"
      assert message =~ "start grant"

      Enable.run(args)
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "is already waiting"
      assert length(publish_requests(ctx)) == 1
    end

    test "with the sole-administrator opt-in, the only administrator is told to approve", %{
      ctx: ctx
    } do
      Enable.run([
        "--org",
        ctx.tenant,
        "--as",
        to_string(ctx.user.email),
        "--sole-administrator-approval"
      ])

      assert_received {:mix_shell, :info, [opted_in]}
      assert opted_in =~ "allows its sole administrator to approve"
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "approve it yourself"
    end

    test "refuses a person who is not a member of the organization", %{ctx: ctx} do
      other = tenant!()

      assert_raise Mix.Error, ~r/is not a member/, fn ->
        Enable.run(["--org", ctx.organization.unique_name, "--as", to_string(other.user.email)])
      end
    end
  end
end
