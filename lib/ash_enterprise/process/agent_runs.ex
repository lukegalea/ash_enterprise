defmodule AshEnterprise.Process.AgentRuns do
  @moduledoc """
  A process hands work to an agent and waits for it: the two service tasks around the
  wait (`AshEnterprise.Process.ActionInvoker`'s `start_agent_run` and `agent_run_outcome`).

      service task   start_agent_run      -> promotes `run_id`
      receive task   waits for the run's CloudEvents envelope (`RunFinished`),
                     correlated on `routing.run_id`, with a timer boundary for the timeout
      service task   agent_run_outcome    -> promotes `outcome`
      gateway        routes on `routing.outcome`

  A timeout leaves the wait by the boundary; `cancel_agent_run` there stops the run that is
  still working for a process that has stopped waiting, and the flow then goes to the same
  `agent_run_outcome` task and gateway, with `cancelled` routed to the timed-out end. The
  message is the only wake a token has, and the receive task's lookback covers a run that
  finished moments before the token parked, not a wait that began long after (a worker that
  died and was redelivered late, a sweep that was down). That run is complete, `cancel` leaves
  a final run alone, and routing on how the run ended reports it as it ended and not as timed
  out.

  ## Starting the run

  The run is started as the person who started the instance, the same identity a service
  task that names a declared target runs as (`AshEnterprise.Process.ServiceInvocation`): the
  agent's start grant is theirs to hold, and a starter who has left stops the task before
  anything is written. The run's key is the engine's invocation key, `bpmn:<instance>:<token>:<node>`,
  the same for every redelivery of the node, so a redelivery after the first delivery started
  the run finds that run and starts none. The task's inputs are the agent's key (`agent`) and
  what it is asked (`input`), both declared in the diagram.

  ## What the message says, and what the process asks

  The envelope says a run finished. How it ended is read from the run, as the starter, by
  the second task, so a process routes on what the run recorded and not on a message that
  could be replayed or forged by anything that writes the audit log. A run that is not final
  yet is an error the node retries.

  Reached through the allowlist in `ActionInvoker`, not as an `ash:call` callable: the engine
  calls a callable as its own actor, which this application's policies do not know, and the
  run must belong to a person.
  """

  alias AshEnterprise.Execution
  alias AshEnterprise.Faults
  alias AshEnterprise.Process.{EngineContext, ServiceInvocation}

  @final [:completed, :failed, :cancelled]

  @doc "Starts the run the node asks for, or finds the one an earlier delivery started."
  @spec start(map()) :: {:ok, map()} | {:error, term()}
  def start(ctx) do
    tenant = EngineContext.tenant(ctx)

    with {:ok, key, %{"process_instance_id" => instance_id}} <- ServiceInvocation.position(ctx),
         {:ok, agent} <- input(ctx, "agent"),
         {:ok, prompt} <- input(ctx, "input"),
         {:ok, starter} <- ServiceInvocation.starter(ctx[:instance], tenant),
         {:ok, run} <- run(key, agent, prompt, instance_id, starter, tenant) do
      # The run exists and the engine has not yet recorded the advance.
      Faults.point(:process_agent_run_started)
      {:ok, %{"run_id" => run.id}}
    end
  end

  @doc "How the run the token waited for ended: `completed`, `failed` or `cancelled`."
  @spec outcome(map()) :: {:ok, map()} | {:error, term()}
  def outcome(ctx) do
    tenant = EngineContext.tenant(ctx)

    with {:ok, run_id} <- input(ctx, "run_id"),
         {:ok, starter} <- ServiceInvocation.starter(ctx[:instance], tenant),
         {:ok, run} <- Execution.get_agent_run(run_id, actor: starter, tenant: tenant) do
      if run.status in @final do
        # The run is read and the engine has not yet recorded the advance.
        Faults.point(:process_agent_run_outcome_read)
        {:ok, %{"outcome" => to_string(run.status), "error_code" => run.error_code}}
      else
        {:error, {:agent_run_not_finished, run.id, run.status}}
      end
    end
  end

  @doc """
  Cancels the run the token stopped waiting for (its timeout), unless it has finished in the
  meantime. A redelivery finds it cancelled and says so again.
  """
  @spec cancel(map()) :: :ok | {:error, term()}
  def cancel(ctx) do
    tenant = EngineContext.tenant(ctx)

    with {:ok, run_id} <- input(ctx, "run_id"),
         {:ok, starter} <- ServiceInvocation.starter(ctx[:instance], tenant),
         {:ok, run} <- Execution.get_agent_run(run_id, actor: starter, tenant: tenant) do
      stop(run, ctx)
    end
  end

  defp stop(%{status: status}, _ctx) when status in @final, do: :ok

  # Read as the starter, who owns the run; cancelled as the process, which is what stopped
  # waiting.
  defp stop(run, ctx) do
    with {:ok, _run} <- Execution.request_agent_run_cancel(run, EngineContext.engine_opts(ctx)),
         do: :ok
  end

  defp run(key, agent, prompt, instance_id, starter, tenant) do
    opts = [actor: starter, tenant: tenant]

    case Execution.get_agent_run_by_key(key, opts ++ [not_found_error?: false]) do
      {:ok, %{} = run} ->
        {:ok, run}

      {:ok, nil} ->
        Execution.start_agent_run(
          agent,
          prompt,
          %{run_key: key, origin: :bpmn},
          opts ++ [context: %{process_instance_id: instance_id}]
        )

      {:error, _} = error ->
        error
    end
  end

  defp input(ctx, name) do
    case ctx[:inputs] do
      %{^name => value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_input, name}}
    end
  end
end
