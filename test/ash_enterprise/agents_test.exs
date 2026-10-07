defmodule AshEnterprise.AgentsTest do
  @moduledoc """
  Epic E5 acceptance: the OMP bridge lifecycle, the tool gate's exact
  binding, the clean failure when the omp binary is absent, and the ash_ai
  tool declarations.

  Every test drives a **fake** `omp` executable — a shell script speaking the
  documented line protocol (see `AshEnterprise.Agents.OmpSession`'s moduledoc)
  — so the suite is deterministic and never spawns a real coding agent. The
  workspace each session points at is a scratch directory under the system
  tmp dir, never this repository.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Agents
  alias AshEnterprise.Agents.AgentMessage
  alias AshEnterprise.Agents.AgentRun
  alias AshEnterprise.Agents.AgentSession
  alias AshEnterprise.Agents.OmpSession
  alias AshEnterprise.Agents.ToolGate
  alias AshEnterprise.Agents.ToolInvocation

  @opts [authorize?: false]

  setup do
    dir = Path.join(System.tmp_dir!(), "agents-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    previous = Application.get_env(:ash_enterprise, :omp_binary)
    on_exit(fn -> Application.put_env(:ash_enterprise, :omp_binary, previous) end)

    # Tenant resources: the session (and through it the run) belongs to an
    # organization, and the bridge inherits that tenant for its own writes.
    org =
      AshEnterprise.Accounts.Organization
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Agents Test", unique_name: "agents-test-#{System.unique_integer([:positive])}"},
        @opts
      )
      |> Ash.create!()

    # The operator: sessions and runs stamp ownership from the actor.
    user =
      AshEnterprise.Accounts.User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "operator@agents.test",
          password: "password1234",
          password_confirmation: "password1234"
        },
        @opts
      )
      |> Ash.create!()

    %{dir: dir, tenant: org.id, actor: user}
  end

  describe "run lifecycle with the fake omp executable" do
    test "start → prompt and agent messages land → run completes", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      write_omp(dir, """
      read -r line
      echo '{"type":"message","text":"line one"}'
      echo '{"type":"message","text":"line two"}'
      """)

      run = start_run!(dir, "rewrite the parser", tenant, actor)

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, authorize?: false)
          if run.status == :completed, do: {:ok, run}
        end)

      assert run.started_at
      assert run.finished_at
      assert DateTime.compare(run.finished_at, run.started_at) in [:gt, :eq]

      texts =
        run.id
        |> AgentMessage.for_run!(authorize?: false)
        |> Enum.map(&{&1.role, &1.text})

      assert {:user, "rewrite the parser"} in texts
      assert {:agent, "line one"} in texts
      assert {:agent, "line two"} in texts
    end

    test "a nonzero exit fails the run", %{dir: dir, tenant: tenant, actor: actor} do
      write_omp(dir, """
      read -r line
      echo '{"type":"message","text":"about to blow up"}'
      exit 3
      """)

      run = start_run!(dir, "explode", tenant, actor)

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, authorize?: false)
          if run.status == :failed, do: {:ok, run}
        end)

      assert run.finished_at

      texts = Enum.map(AgentMessage.for_run!(run.id, authorize?: false), & &1.text)
      assert "about to blow up" in texts
      assert Enum.any?(texts, &(&1 =~ "exited with status 3"))
    end

    test "cancelling a live run stops the session and marks the run cancelled", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      write_omp(dir, """
      read -r line
      exec sleep 60
      """)

      run = start_run!(dir, "too slow", tenant, actor)

      eventually(fn ->
        case Registry.lookup(AshEnterprise.Agents.Registry, run.id) do
          [{_pid, _}] -> {:ok, :live}
          [] -> :retry
        end
      end)

      assert {:ok, :cancelling} = OmpSession.cancel(run)

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, authorize?: false)
          if run.status == :cancelled, do: {:ok, run}
        end)

      assert run.finished_at

      eventually(fn ->
        case Registry.lookup(AshEnterprise.Agents.Registry, run.id) do
          [] -> {:ok, :gone}
          _ -> :retry
        end
      end)
    end
  end

  describe "tool gate" do
    test "tool request → pending invocation pauses the run → approval resumes it exactly bound",
         %{dir: dir, tenant: tenant, actor: actor} do
      write_omp(dir, """
      read -r line
      echo '{"type":"tool_request","id":"req-1","tool":"write_file","input":{"path":"lib/x.ex","bytes":3}}'
      read -r response
      echo "{\\"type\\":\\"tool_result\\",\\"id\\":\\"req-1\\",\\"result\\":{\\"written\\":true,\\"response\\":$response}}"
      echo '{"type":"message","text":"resumed"}'
      """)

      run = start_run!(dir, "make a change", tenant, actor)

      invocation =
        eventually(fn ->
          case ToolInvocation.for_run!(run.id, authorize?: false) do
            [%{status: :pending} = invocation] -> {:ok, invocation}
            _ -> :retry
          end
        end)

      assert invocation.tool_name == "write_file"
      assert invocation.input == %{"path" => "lib/x.ex", "bytes" => 3}
      assert invocation.request_id == "req-1"

      # Paused means paused: no writes go to the port while the gate is shut.
      refute Enum.any?(AgentMessage.for_run!(run.id, authorize?: false), &(&1.text == "resumed"))

      {:ok, approved} = ToolGate.approve_invocation(invocation, authorize?: false)
      assert approved.status == :approved

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, authorize?: false)
          if run.status == :completed, do: {:ok, run}
        end)

      # The decision reached the process and was bound back into the result:
      # the script echoes our tool_response object inside its tool_result.
      invocation = ToolInvocation.by_id!(invocation.id, authorize?: false)
      assert invocation.status == :completed
      assert invocation.result["written"] == true
      assert invocation.result["response"]["approved"] == true
      assert invocation.result["response"]["id"] == "req-1"

      assert Enum.any?(AgentMessage.for_run!(run.id, authorize?: false), &(&1.text == "resumed"))

      # Exactly bound: an already-decided invocation cannot be approved again.
      assert {:error, _} = ToolGate.approve_invocation(invocation, authorize?: false)
    end

    test "rejection fails the invocation and the run resumes without the tool", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      write_omp(dir, """
      read -r line
      echo '{"type":"tool_request","id":"req-1","tool":"shell","input":{"cmd":"rm -rf /"}}'
      read -r response
      echo "$response"
      echo '{"type":"message","text":"got the rejection"}'
      """)

      run = start_run!(dir, "do something dangerous", tenant, actor)

      invocation =
        eventually(fn ->
          case ToolInvocation.for_run!(run.id, authorize?: false) do
            [%{status: :pending} = invocation] -> {:ok, invocation}
            _ -> :retry
          end
        end)

      {:ok, rejected} = ToolGate.reject_invocation(invocation, authorize?: false)
      assert rejected.status == :rejected

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, authorize?: false)
          if run.status == :completed, do: {:ok, run}
        end)

      invocation = ToolInvocation.by_id!(invocation.id, authorize?: false)
      assert invocation.status == :rejected
      refute invocation.result

      # The process heard the rejection on the wire: it echoed the
      # tool_response line back, and the bridge kept it as a transcript row.
      assert Enum.any?(AgentMessage.for_run!(run.id, authorize?: false), fn message ->
               case Jason.decode(message.text) do
                 {:ok, %{"type" => "tool_response", "id" => "req-1", "approved" => false}} ->
                   true

                 _ ->
                   false
               end
             end)

      assert Enum.any?(
               AgentMessage.for_run!(run.id, authorize?: false),
               &(&1.text == "got the rejection")
             )
    end
  end

  describe "missing omp binary" do
    test "start_run fails the run cleanly with a clear message", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      Application.put_env(:ash_enterprise, :omp_binary, "definitely-not-omp-on-path")

      run = start_run!(dir, "will not start", tenant, actor)

      # The bridge failed the run in its own transaction after the action
      # committed; the record the action returned predates that.
      run = AgentRun.by_id!(run.id, tenant: tenant, authorize?: false)

      assert run.status == :failed
      assert run.finished_at

      # start_run/1 reports the missing binary to direct callers too.
      assert {:error, :omp_binary_missing} = OmpSession.start_run(run)

      assert process_gone?(run.id)

      texts = Enum.map(AgentMessage.for_run!(run.id, authorize?: false), & &1.text)
      assert "will not start" in texts
      assert Enum.any?(texts, &(&1 =~ "definitely-not-omp-on-path" and &1 =~ "not found on PATH"))
    end
  end

  describe "ash_ai exposure" do
    test "only the read actions are typed tools — never run-start (no nesting)" do
      tools = AshAi.Info.tools(Agents)
      names = MapSet.new(tools, & &1.name)

      assert MapSet.subset?(MapSet.new([:list_agent_sessions, :list_agent_runs]), names)
      refute :start_agent_run in names

      assert Enum.find(tools, &(&1.name == :list_agent_sessions)).resource == AgentSession
      assert Enum.find(tools, &(&1.name == :list_agent_runs)).resource == AgentRun
    end

    test "the surface stays fail-closed: an anonymous actor sees and does nothing" do
      # Reads are FilterChecks: they narrow to nothing instead of 403ing.
      assert [] = Ash.read!(AgentSession)

      # Writes have nothing to filter: they are refused outright (default
      # authorize?: true, no actor).
      assert_raise Ash.Error.Forbidden, fn ->
        AgentSession.open!(%{title: "nope", workspace_path: "/tmp/nope"})
      end
    end
  end

  # --- helpers -----------------------------------------------------------------

  # Writes a fake `omp` executable speaking the documented line protocol.
  defp write_omp(dir, body) do
    path = Path.join(dir, "omp")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    Application.put_env(:ash_enterprise, :omp_binary, path)
    path
  end

  defp start_run!(dir, prompt, tenant, actor) do
    session =
      AgentSession.open!(%{title: "test session", workspace_path: dir},
        tenant: tenant,
        actor: actor,
        authorize?: false
      )

    AgentRun.start!(session.id, prompt, tenant: tenant, actor: actor, authorize?: false)
  end

  defp process_gone?(run_id) do
    Registry.lookup(AshEnterprise.Agents.Registry, run_id) == []
  end

  defp eventually(fun, tries \\ 200)

  defp eventually(fun, tries) do
    case fun.() do
      {:ok, value} ->
        value

      _ when tries <= 1 ->
        flunk("condition was not met in time")

      _ ->
        Process.sleep(25)
        eventually(fun, tries - 1)
    end
  end
end
