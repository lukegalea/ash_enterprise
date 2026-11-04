defmodule AshEnterprise.AgentsTest do
  @moduledoc """
  Epic E5 acceptance: the OMP bridge lifecycle, a tool call's exact binding
  to its invocation (ADR 0055), the clean failure when the omp binary is absent, and the ash_ai
  tool declarations.

  Every test drives a **fake** `omp` executable — a shell script speaking the
  documented line protocol (see `AshEnterprise.Agents.OmpSession`'s moduledoc)
  — so the suite is deterministic and never spawns a real coding agent. The
  workspace each session points at is a scratch directory under the system
  tmp dir, never this repository.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  require Ash.Query

  alias AshEnterprise.Agents
  alias AshEnterprise.Agents.AgentMessage
  alias AshEnterprise.Agents.AgentRun
  alias AshEnterprise.Agents.AgentSession
  alias AshEnterprise.Agents.OmpSession
  alias AshEnterprise.Agents.ToolCall
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Actions.ConfirmInvocation
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.SystemActor

  setup do
    dir = Path.join(System.tmp_dir!(), "agents-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    previous = Application.get_env(:ash_enterprise, :omp_binary)
    on_exit(fn -> Application.put_env(:ash_enterprise, :omp_binary, previous) end)

    # The operator, a member of the tenant: the session (and through it the run)
    # belongs to its organization, sessions and runs stamp ownership from the
    # actor, and a tool call is asked as them.
    %{actor: actor, tenant: tenant} = tenant!()
    %{dir: dir, tenant: tenant, actor: actor}
  end

  describe "run lifecycle with the fake omp executable" do
    test "start → prompt and agent messages land → run completes", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      write_omp(dir, """
      read -r line
      printf '%s\\n' "$line" > prompt-frame.json
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

      # The prompt frame is OMP's actual `prompt` command shape (rpc-types.ts):
      # {id, type: "prompt", message} — the id correlates prompt_result, and
      # the text lives in `message`. The old {type, text} shape is what real
      # omp rejected with "undefined is not an object (evaluating 'le.trim')".
      frame = dir |> Path.join("prompt-frame.json") |> File.read!() |> Jason.decode!()

      assert %{"type" => "prompt", "id" => id, "message" => "rewrite the parser"} = frame
      assert is_binary(id) and id != ""
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

    test "prompt_result completes the run while the process stays alive", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      # The real OMP keeps serving turns after one finishes: the run is the
      # prompt, so its prompt_result (correlated on the id we sent) — not the
      # process exit — is what settles the run. The fake echoes our id back
      # from the prompt frame, exactly as omp correlates it, then idles.
      write_omp(dir, """
      read -r line
      printf '%s\\n' "$line" > prompt-frame.json
      ID=$(printf '%s' "$line" | grep -o '"id":"[a-f0-9-]*"' | cut -d'"' -f4)
      echo "{\\"type\\":\\"prompt_result\\",\\"id\\":\\"$ID\\",\\"agentInvoked\\":true,\\"status\\":\\"completed\\",\\"sessionSettled\\":true}"
      exec sleep 30
      """)

      run = start_run!(dir, "one unit of work", tenant, actor)

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, tenant: tenant, authorize?: false)
          if run.status == :completed, do: {:ok, run}
        end)

      assert run.finished_at

      # Process still alive, run already terminal — cancel is just shutdown
      # now, and it must not move the terminal row.
      eventually(fn ->
        if Registry.lookup(AshEnterprise.Agents.Registry, run.id) != [],
          do: {:ok, :live},
          else: :retry
      end)

      assert {:ok, :cancelling} = OmpSession.cancel(run)

      eventually(fn ->
        if Registry.lookup(AshEnterprise.Agents.Registry, run.id) == [],
          do: {:ok, :gone},
          else: :retry
      end)

      run = AgentRun.by_id!(run.id, tenant: tenant, authorize?: false)
      assert run.status == :completed
    end

    test "prompt_result error fails the run with the provider's message", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      write_omp(dir, """
      read -r line
      ID=$(printf '%s' "$line" | grep -o '"id":"[a-f0-9-]*"' | cut -d'"' -f4)
      echo "{\\"type\\":\\"prompt_result\\",\\"id\\":\\"$ID\\",\\"status\\":\\"error\\",\\"error\\":{\\"message\\":\\"provider down\\"}}"
      exec sleep 30
      """)

      run = start_run!(dir, "will error", tenant, actor)

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, tenant: tenant, authorize?: false)
          if run.status == :failed, do: {:ok, run}
        end)

      assert run.finished_at

      texts = Enum.map(AgentMessage.for_run!(run.id, authorize?: false), & &1.text)
      assert Enum.any?(texts, &(&1 == "prompt failed: provider down"))

      # Run terminal, process still alive: cancel is pure shutdown now.
      assert {:ok, :cancelling} = OmpSession.cancel(run)

      eventually(fn ->
        if Registry.lookup(AshEnterprise.Agents.Registry, run.id) == [],
          do: {:ok, :gone},
          else: :retry
      end)
    end

    test "the orphan sweep fails a run whose session died, but not one that is live", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      # The sweep's guard matters as much as its action: a live session must
      # survive a sweep call (the boot task can race a fresh run), while the
      # run orphaned by a dead bridge instance gets failed.
      write_omp(dir, """
      read -r line
      echo '{"type":"message","text":"still here"}'
      exec sleep 30
      """)

      live = start_run!(dir, "live run", tenant, actor)

      eventually(fn ->
        run = AgentRun.by_id!(live.id, authorize?: false)
        if run.status == :running, do: {:ok, :running}, else: :retry
      end)

      # Orphan a second run the way a BEAM restart would: terminate the
      # session (terminate, not kill — a restart would re-run init and
      # re-spawn OMP against the same run).
      write_omp(dir, """
      read -r line
      exec sleep 60
      """)

      doomed = start_run!(dir, "doomed run", tenant, actor)

      pid =
        eventually(fn ->
          case Registry.lookup(AshEnterprise.Agents.Registry, doomed.id) do
            [{pid, _}] -> {:ok, pid}
            [] -> :retry
          end
        end)

      :ok = DynamicSupervisor.terminate_child(AshEnterprise.Agents.OmpSupervisor, pid)

      :ok = OmpSession.fail_orphaned_runs()

      live = AgentRun.by_id!(live.id, tenant: tenant, authorize?: false)
      assert live.status == :running

      doomed = AgentRun.by_id!(doomed.id, tenant: tenant, authorize?: false)
      assert doomed.status == :failed
      assert doomed.finished_at

      texts = Enum.map(AgentMessage.for_run!(doomed.id, authorize?: false), & &1.text)
      assert Enum.any?(texts, &(&1 =~ "bridge restarted"))

      # Cleanup: the live run's sleeper must not outlive the test — and the
      # session must finish its terminal transition before the sandbox owner
      # stops, or a straggler Ash call from it poisons the shared connection
      # for the next test.
      assert {:ok, :cancelling} = OmpSession.cancel(live)

      eventually(fn ->
        if Registry.lookup(AshEnterprise.Agents.Registry, live.id) == [],
          do: {:ok, :gone},
          else: :retry
      end)

      live = AgentRun.by_id!(live.id, tenant: tenant, authorize?: false)
      assert live.status == :cancelled
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

  describe "tool calls are invocations" do
    test "tool request → invocation awaiting approval pauses the run → confirming resumes it exactly bound",
         %{dir: dir, tenant: tenant, actor: actor} do
      write_omp(dir, """
      read -r line
      echo '{"type":"tool_request","id":"req-1","tool":"write_file","input":{"path":"lib/x.ex","bytes":3}}'
      read -r response
      echo "{\\"type\\":\\"tool_result\\",\\"id\\":\\"req-1\\",\\"result\\":{\\"written\\":true,\\"response\\":$response}}"
      echo '{"type":"message","text":"resumed"}'
      """)

      run = start_run!(dir, "make a change", tenant, actor)
      call = awaiting_call!(run, "req-1", tenant)

      assert call.owner_id == actor.id

      assert args(call, tenant) == %{
               "run_id" => run.id,
               "request_id" => "req-1",
               "tool" => "write_file",
               "input" => %{"path" => "lib/x.ex", "bytes" => 3}
             }

      # Paused means paused: no writes go to the port while the call waits.
      refute Enum.any?(AgentMessage.for_run!(run.id, authorize?: false), &(&1.text == "resumed"))

      {:ok, dispatched} = ConfirmInvocation.confirm(call, actor, tenant)
      assert dispatched.status == :dispatched

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, authorize?: false)
          if run.status == :completed, do: {:ok, run}
        end)

      # The decision reached the process and was bound back into the result:
      # the script echoes our tool_response object inside its tool_result.
      done =
        eventually(fn ->
          row = row!(call.id, tenant)
          if row.status == :succeeded, do: {:ok, row}
        end)

      result = Ash.load!(done, [:result], actor: SystemActor.oban(), tenant: tenant).result
      assert result["written"] == true

      assert result["response"] == %{
               "type" => "tool_response",
               "id" => "req-1",
               "approved" => true
             }

      assert Enum.any?(AgentMessage.for_run!(run.id, authorize?: false), &(&1.text == "resumed"))

      # Exactly bound: a decided call has nothing left to approve, and the same
      # request asked again is the same row.
      assert {:ok, %{status: :succeeded}} = ConfirmInvocation.confirm(done, actor, tenant)
      assert [_one] = calls(run, tenant)
    end

    test "rejection fails the call and the run resumes without the tool", %{
      dir: dir,
      tenant: tenant,
      actor: actor
    } do
      write_omp(dir, """
      read -r line
      echo '{"type":"tool_request","id":"req-1","tool":"shell","input":{"cmd":"rm -rf /"}}'
      read -r response
      printf '%s\\n' "$response" > tool-response.json
      echo '{"type":"message","text":"got the rejection"}'
      """)

      run = start_run!(dir, "do something dangerous", tenant, actor)
      call = awaiting_call!(run, "req-1", tenant)

      {:ok, rejected} = ConfirmInvocation.decline(call, actor, tenant)
      assert rejected.status == :rejected

      run =
        eventually(fn ->
          run = AgentRun.by_id!(run.id, authorize?: false)
          if run.status == :completed, do: {:ok, run}
        end)

      assert %{status: :rejected, error_code: "approval_rejected"} = row!(call.id, tenant)

      # The process heard the rejection on the wire: it wrote the exact
      # tool_response line it received to the workspace.
      response_frame =
        dir |> Path.join("tool-response.json") |> File.read!() |> Jason.decode!()

      assert response_frame == %{
               "type" => "tool_response",
               "id" => "req-1",
               "approved" => false
             }

      assert Enum.any?(
               AgentMessage.for_run!(run.id, authorize?: false),
               &(&1.text == "got the rejection")
             )
    end

    test "a tool call runs only as its invocation", %{tenant: tenant, actor: actor} do
      assert {:error, _refused} =
               ToolCall
               |> Ash.ActionInput.for_action(
                 :run_tool,
                 %{run_id: Ash.UUID.generate(), tool: "shell", input: %{}},
                 actor: actor,
                 tenant: tenant
               )
               |> Ash.run_action()
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

  defp calls(run, tenant) do
    Invocation
    |> Ash.Query.filter(target == ^ToolCall.target())
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.filter(&String.starts_with?(&1.invocation_key, "omp:#{run.id}:"))
  end

  defp awaiting_call!(run, request_id, tenant) do
    key = ToolCall.key(run.id, request_id)

    eventually(fn ->
      case Enum.find(calls(run, tenant), &(&1.invocation_key == key)) do
        %{status: :awaiting_approval} = row -> {:ok, row}
        _not_yet -> :retry
      end
    end)
  end

  defp row!(id, tenant),
    do: Execution.get_invocation!(id, actor: SystemActor.oban(), tenant: tenant)

  defp args(row, tenant),
    do: Ash.load!(row, [:args], actor: SystemActor.oban(), tenant: tenant).args

  defp process_gone?(run_id) do
    Registry.lookup(AshEnterprise.Agents.Registry, run_id) == []
  end

  # 15s under load: focused runs finish in seconds, but sibling suites on
  # this box can starve the port-and-database dance; the happy path pays
  # nothing (the first check usually wins).
  defp eventually(fun, tries \\ 600)

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
