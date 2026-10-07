defmodule AshEnterprise.Agents.OmpSession do
  @moduledoc """
  One `omp --mode rpc` child process per run (dogfood §6), supervised through
  `AshEnterprise.Agents.OmpSupervisor` and registered by run id in
  `AshEnterprise.Agents.Registry`.

  ## Wire contract

  Newline-delimited JSON over the port's stdio (E3's stdio seam, one process
  per run). Frames OMP speaks are authoritative in
  `@oh-my-pi/pi-coding-agent` `src/modes/rpc/rpc-types.ts` (`--mode rpc`
  accepts `{id?, type, ...}` commands and streams responses/events); frames
  the bridge adds on top are the bridge dialect, spoken by the fake
  executable in tests and available to any future adapter.

  What the bridge writes:

      {"id":<corr>,"type":"prompt","message":<run prompt>}      — on start (OMP protocol)
      {"type":"tool_response","id":<id>,"approved":true|false}  — on a ToolGate decision (bridge dialect)

  What the bridge understands coming back:

      {"type":"message","text":...}                             → :agent message (bridge dialect)
      {"type":"tool_request","id":...,"tool":...,"input":{...}} → pending ToolInvocation, run paused (bridge dialect)
      {"type":"tool_result","id":...,"result":{...}}            → invocation completed (bridge dialect)
      {"type":"response",...,success:false}                     → :tool diagnostic (OMP protocol)
      {"type":"prompt_result",status:"error",...}               → :tool diagnostic (OMP protocol)
      {"type":"message_end","message":{role:"assistant",...}}   → assistant text parts → :agent message (OMP protocol)

  Every other frame (`ready`, `response` success acks, `extension_ui_request`,
  `advisor_cost_changed`, command updates, ...) is the runtime's *state*, not
  the conversation: dogfood §6's division of labor keeps it out of the
  transcript — debug-logged, never an AgentMessage. Non-JSON lines (the
  process speaking for itself, stderr merged into the channel) are kept
  verbatim as :agent messages so agent output is never dropped.

  A tool request pauses the run: no further writes go to the port until
  `AshEnterprise.Agents.ToolGate` resolves the pending invocation, which is
  also what resumes it — the response write *is* the resume. This is ADR 0015
  in miniature: approvals are resource rows, exactly bound to the invocation
  they decide.

  ## Process discipline

  Port writes never block this GenServer's queue: a linked writer process owns
  `Port.command/2` and buffers while the run is paused. The session never
  deliberately crashes, and never re-spawns OMP after a restart: a write error
  is logged and the run stays for an operator to cancel — the alternative
  (supervisor restart re-running `init`) would launch a second agent process
  against the same run. `restart: :transient`, `{:stop, :normal}` on terminal
  handling.

  `authorize?: false` on every Ash call: the bridge is infrastructure (the
  worker context of the discipline rules), acting on runs that were already
  policy-checked when their action ran. Provenance stamping still applies.
  """

  use GenServer, restart: :transient

  require Logger

  alias AshEnterprise.Agents.AgentMessage
  alias AshEnterprise.Agents.AgentRun
  alias AshEnterprise.Agents.AgentSession
  alias AshEnterprise.Agents.ToolInvocation

  @line_bytes 65_536
  # How long an eof waits for its exit_status before "went mute while alive"
  # is the conclusion. Far longer than the driver takes to reap an exited
  # child, far shorter than anyone waits on a mute agent.
  @eof_grace_ms 100
  @binary_env :omp_binary

  # --- client API --------------------------------------------------------------

  @doc """
  Starts one OMP RPC process for `run` in its session's workspace, streaming
  output into `AgentMessage` rows and pausing on tool requests.

  With the omp binary absent (dev machines need not have it), the run is
  failed cleanly — status `:failed` with the reason as a transcript message —
  and `{:error, :omp_binary_missing}` is returned. This is also the seam the
  tests drive with a fake executable (`config :ash_enterprise, :omp_binary`).
  """
  @spec start_run(AgentRun.t()) :: {:ok, pid()} | {:error, :omp_binary_missing}
  def start_run(%AgentRun{} = run) do
    binary = Application.get_env(:ash_enterprise, @binary_env, "omp")

    case System.find_executable(binary) do
      nil ->
        fail_unstartable(run, binary)
        {:error, :omp_binary_missing}

      path ->
        # The bridge inherits the run's tenant: every write it makes lands in
        # the same organization the run (and its session) belongs to.
        tenant = run.organization_id
        session = AgentSession.by_id!(run.session_id, tenant: tenant, authorize?: false)

        DynamicSupervisor.start_child(AshEnterprise.Agents.OmpSupervisor, {
          __MODULE__,
          run: run, binary: path, workspace_path: session.workspace_path, tenant: tenant
        })
    end
  end

  @doc """
  Cancels a live run: stops the process and marks the run `:cancelled`. A run
  whose session already exited is marked directly.
  """
  @spec cancel(AgentRun.t()) :: {:ok, :cancelling | AgentRun.t()} | {:error, term()}
  def cancel(%AgentRun{} = run) do
    case Registry.lookup(AshEnterprise.Agents.Registry, run.id) do
      [{pid, _}] ->
        GenServer.cast(pid, :cancel)
        {:ok, :cancelling}

      [] ->
        AgentRun.cancel(run, authorize?: false)
    end
  end

  @doc """
  Delivers a tool decision to the live session: resumes the run and writes the
  `tool_response` line binding `request_id` to `approved?`. Best-effort — a
  session that already exited has nothing to resume; the resource row is the
  decision of record either way.
  """
  @spec tool_response(String.t() | nil, String.t() | nil, boolean()) :: :ok
  def tool_response(run_id, request_id, approved?) do
    case Registry.lookup(AshEnterprise.Agents.Registry, run_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:tool_response, request_id, approved?})
        :ok

      [] ->
        Logger.warning(
          "tool decision for run #{inspect(run_id)} arrived after its session exited; the resource row is the record"
        )

        :ok
    end
  end

  @doc """
  Fails every `:running` run that has no live session process — work orphaned
  by a bridge restart (BEAM restart, crashed session). The exit_status that
  would finalize such a run died with the old instance, so nothing in-process
  can ever deliver it; the sweep is what runs at boot instead. Supervised
  one-shot task child next to `AshEnterprise.Agents.OmpSupervisor`.
  """
  @spec fail_orphaned_runs() :: :ok
  def fail_orphaned_runs do
    require Ash.Query

    running = Ash.read!(Ash.Query.filter(AgentRun, status == :running), authorize?: false)

    for run <- running do
      if Registry.lookup(AshEnterprise.Agents.Registry, run.id) == [] do
        append_message!(
          run.id,
          :tool,
          "agent process exited (bridge restarted before the run finished)",
          run.organization_id,
          run.owner_id
        )

        case AgentRun.fail(run, tenant: run.organization_id, authorize?: false) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Logger.error("could not fail orphaned run #{run.id}: #{inspect(error)}")
        end
      end
    end

    :ok
  end

  # --- GenServer ---------------------------------------------------------------

  @doc false
  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)
    GenServer.start_link(__MODULE__, opts, name: via(run.id))
  end

  @impl true
  def init(opts) do
    run = Keyword.fetch!(opts, :run)
    binary = Keyword.fetch!(opts, :binary)
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    tenant = Keyword.fetch!(opts, :tenant)

    # The transcript opens with the prompt itself, before the process can
    # speak: the run's first line is the thing that caused the run.
    append_message!(run.id, :user, run.prompt, tenant, run.owner_id)

    port =
      Port.open(
        {:spawn_executable, binary},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :eof,
          {:line, @line_bytes},
          {:args, ["--mode", "rpc"]},
          {:cd, workspace_path}
        ]
      )

    writer = spawn_link(fn -> writer_loop(port, false, []) end)

    # OMP's `prompt` command (rpc-types.ts): {id?, type: "prompt", message}.
    # The id correlates the eventual prompt_result/response; `message` is the
    # text field — OMP trims it on arrival, so nothing else will do.
    prompt_id = Ash.UUID.generate()
    write_line(writer, Jason.encode!(%{id: prompt_id, type: "prompt", message: run.prompt}))

    {:ok,
     %{
       run_id: run.id,
       tenant: tenant,
       owner_id: run.owner_id,
       prompt_id: prompt_id,
       port: port,
       writer: writer,
       buffer: <<>>,
       pending: MapSet.new(),
       terminated?: false
     }}
  end

  @impl true
  def handle_cast(:cancel, state) do
    state = stop_child(state)

    terminal_state(state, fn run ->
      AgentRun.cancel(run, tenant: state.tenant, authorize?: false)
    end)
  end

  def handle_cast({:tool_response, request_id, approved?}, state) do
    write_line(
      state.writer,
      Jason.encode!(%{
        type: "tool_response",
        id: response_id(request_id, state),
        approved: approved?
      })
    )

    # The response write is the resume: nothing else is ever queued while a
    # request is outstanding, so an emptied pending set is the unpause.
    state = %{state | pending: MapSet.delete(state.pending, request_id)}

    if Enum.empty?(state.pending) do
      send(state.writer, :resume)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {:noreply, process_line(state, state.buffer <> line)}
  end

  def handle_info({port, {:data, {:noeol, partial}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> partial}}
  end

  def handle_info({port, :eof}, %{port: port} = state) do
    # An unterminated final line is still a line.
    buffer = state.buffer
    state = process_line(%{state | buffer: <<>>}, buffer)

    # stdout closed. Two very different cases share this moment: a process
    # that exited (its exit_status is right behind the eof — let it finalize
    # the run) and a process that went mute while still alive (a dead
    # protocol that must never leave an eternal :running row). A short grace
    # period tells them apart without racing the driver's reaping.
    Process.send_after(self(), {:eof_check, port}, @eof_grace_ms)
    {:noreply, state}
  end

  def handle_info({:eof_check, port}, %{port: port, terminated?: false} = state) do
    # Backstop for an eof that was never followed by an exit_status — the
    # driver lost the exit (abnormal reaping). In practice ERTS keeps a
    # hidden dup of the child's pipe, so eof arrives only at process death,
    # paired with the exit_status that finalizes the run first; a process
    # that goes mute while alive produces NO port signal at all. That class
    # is covered by cancel/2 (the operator's act) and fail_orphaned_runs/0
    # (the boot sweep), not by anything observable on the port.
    state = %{stop_child(state) | terminated?: true}

    terminal_state(state, fn run ->
      append_message!(
        run.id,
        :tool,
        "agent process exited (closed its output before finishing)",
        state.tenant,
        state.owner_id
      )

      AgentRun.fail(run, tenant: state.tenant, authorize?: false)
    end)
  end

  def handle_info({:eof_check, _port}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if state.terminated? do
      {:noreply, state}
    else
      buffer = state.buffer

      state
      |> Map.put(:buffer, <<>>)
      |> process_line(buffer)
      |> stop_child()
      |> terminal_state(fn run ->
        if status == 0 do
          AgentRun.complete(run, tenant: state.tenant, authorize?: false)
        else
          append_message!(
            run.id,
            :tool,
            "omp exited with status #{status}",
            state.tenant,
            state.owner_id
          )

          AgentRun.fail(run, tenant: state.tenant, authorize?: false)
        end
      end)
    end
  end

  # A message for a port this session no longer owns (post-terminate race):
  # drop it rather than crash into a respawn loop.
  def handle_info({other_port, _message}, %{port: port} = state) when other_port != port do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    unless state.terminated? do
      stop_child(state)
    end

    :ok
  end

  # --- line handling -----------------------------------------------------------

  defp process_line(state, text) do
    case String.trim_trailing(text, "\n") do
      "" -> state
      line -> apply_line(state, line)
    end
  end

  # Each frame has one home. Conversational text becomes transcript; the
  # runtime's control/state frames stay state (debug-logged, per dogfood §6's
  # division of labor); non-JSON output is kept verbatim so the process is
  # never silenced.
  defp apply_line(%{tenant: tenant} = state, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "message", "text" => text}} ->
        append_message!(state.run_id, :agent, text, tenant, state.owner_id)
        state

      {:ok, %{"type" => "tool_request"} = request} ->
        pause_for_invocation(state, line, request)

      {:ok, %{"type" => "tool_result", "id" => id, "result" => result}} ->
        complete_invocation(state, id, result)
        state

      {:ok, %{"type" => "response", "success" => false, "command" => command} = response} ->
        append_message!(
          state.run_id,
          :tool,
          "omp rejected #{command}: #{response["error"]}",
          tenant,
          state.owner_id
        )

        state

      {:ok, %{"type" => "prompt_result", "status" => "error"} = frame} ->
        message = get_in(frame, ["error", "message"]) || "prompt failed"

        append_message!(state.run_id, :tool, "prompt failed: #{message}", tenant, state.owner_id)
        state

      {:ok, %{"type" => "message_end", "message" => message}} ->
        append_conversation_text!(state, message)
        state

      {:ok, decoded} when is_map(decoded) ->
        # ready, response acks, extension_ui_request, advisor_cost_changed,
        # command updates, ... — the runtime talking about itself.
        Logger.debug(fn -> "run #{state.run_id} frame: #{inspect(decoded, limit: 10)}" end)
        state

      {:error, _} ->
        append_message!(state.run_id, :agent, line, tenant, state.owner_id)
        state
    end
  end

  # An OMP assistant message_end carries the full message: text lives in
  # content parts of `type: "text"`. Anything else (roles, shapes) is state.
  defp append_conversation_text!(state, %{"role" => "assistant", "content" => content})
       when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")
      |> String.trim()

    unless text == "" do
      append_message!(state.run_id, :agent, text, state.tenant, state.owner_id)
    end
  end

  defp append_conversation_text!(_state, _message), do: :ok

  # Records the request as a pending invocation and pauses the run: from here
  # the writer buffers until the gate resolves and the response write is the
  # resume.
  defp pause_for_invocation(state, raw_line, request) do
    request_id = request["id"]

    ToolInvocation.record(
      %{
        run_id: state.run_id,
        tool_name: request["tool"] || "unknown",
        input: request["input"] || %{},
        request_id: request_id,
        owner_id: state.owner_id,
        owning_user_id: state.owner_id
      },
      tenant: state.tenant,
      authorize?: false
    )

    append_message!(state.run_id, :tool, raw_line, state.tenant, state.owner_id)
    send(state.writer, :pause)

    %{state | pending: MapSet.put(state.pending, request_id)}
  end

  defp complete_invocation(state, id, result) do
    case Enum.find(
           ToolInvocation.for_run!(state.run_id, tenant: state.tenant, authorize?: false),
           &(&1.request_id == id)
         ) do
      nil ->
        Logger.warning("tool_result for unknown invocation #{inspect(id)} on run #{state.run_id}")

      invocation ->
        # Only an :approved invocation can complete — a rejected one stays
        # rejected even if the process reports a result for it anyway.
        case ToolInvocation.complete(invocation, result, tenant: state.tenant, authorize?: false) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Logger.warning(
              "tool_result rejected for invocation #{invocation.id}: #{inspect(error)}"
            )
        end
    end
  end

  # A request without an id is identified by nothing but the invocation row.
  defp response_id(request_id, state) do
    request_id || Enum.find(MapSet.to_list(state.pending), &(&1 != nil))
  end

  # --- writer (owns all port writes so the GenServer queue never blocks) -------

  defp writer_loop(port, paused?, queue) do
    receive do
      {:write, data} ->
        if paused? do
          writer_loop(port, true, [data | queue])
        else
          Port.command(port, data)
          writer_loop(port, false, queue)
        end

      :pause ->
        writer_loop(port, true, queue)

      :resume ->
        Enum.each(Enum.reverse(queue), &Port.command(port, &1))
        writer_loop(port, false, [])

      :stop ->
        :ok
    end
  end

  defp write_line(writer, line), do: send(writer, {:write, [line, "\n"]})

  # --- terminal handling -------------------------------------------------------

  defp terminal_state(state, transition) do
    run = AgentRun.by_id!(state.run_id, tenant: state.tenant, authorize?: false)

    case transition.(run) do
      {:ok, _run} ->
        :ok

      {:error, error} ->
        # Almost always "already terminal" (a cancellation racing the process
        # exit). The resource row is the record; never crash into a respawn.
        Logger.warning("run #{state.run_id} terminal transition failed: #{inspect(error)}")
    end

    {:stop, :normal, %{state | terminated?: true}}
  end

  defp stop_child(state) do
    send(state.writer, :stop)

    case Port.info(state.port, :os_pid) do
      {:os_pid, os_pid} ->
        # The child was started here; SIGTERM on cancel/exit keeps a slow
        # agent from outliving its run. A dead pid just exits nonzero, and
        # the message it prints about that is noise — captured, not shown.
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    # An external process exit closes the port before :exit_status arrives;
    # closing a closed port raises. Only close one that is still open.
    case Port.info(state.port, :name) do
      {_name, _len} -> Port.close(state.port)
      _ -> :ok
    end

    state
  end

  # --- Ash helpers -------------------------------------------------------------

  defp append_message!(run_id, role, text, tenant, owner_id) do
    case AgentMessage.append(
           %{
             run_id: run_id,
             role: role,
             text: text,
             owner_id: owner_id,
             owning_user_id: owner_id
           },
           tenant: tenant,
           authorize?: false
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        # Losing a transcript line is logged, never fatal: a crashed session
        # would re-spawn OMP against the same run.
        Logger.error("could not append #{role} message to run #{run_id}: #{inspect(error)}")
    end
  end

  defp fail_unstartable(run, binary) do
    # Fresh read: the caller may hold a stale record, and a run re-passed
    # here after already failing must not grow a duplicate transcript — the
    # row's terminal status is the record.
    run = AgentRun.by_id!(run.id, tenant: run.organization_id, authorize?: false)

    if run.status == :running do
      tenant = run.organization_id

      append_message!(run.id, :user, run.prompt, tenant, run.owner_id)

      append_message!(
        run.id,
        :tool,
        "The '#{binary}' binary was not found on PATH. " <>
          "Install omp (or point config :ash_enterprise, :omp_binary at it) and start the run again.",
        tenant,
        run.owner_id
      )

      case AgentRun.fail(run, tenant: tenant, authorize?: false) do
        {:ok, _} -> :ok
        {:error, error} -> Logger.error("could not fail run #{run.id}: #{inspect(error)}")
      end
    end
  end

  defp via(run_id), do: {:via, Registry, {AshEnterprise.Agents.Registry, run_id}}
end
