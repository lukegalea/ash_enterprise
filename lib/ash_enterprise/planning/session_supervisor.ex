defmodule AshEnterprise.Planning.SessionSupervisor do
  @moduledoc """
  Owns one `AshEnterprise.Planning.SolverSession` per live run, named by run id in
  `AshEnterprise.Planning.Registry`.

  A DynamicSupervisor because a solve is an operator event, not a boot-time fact. Sessions are
  `:transient` children and **never restarted into a second solver for the same run**: a
  terminated session is terminal, and the run's lease (`Planning.LeaseSweeper`) decides
  recovery (ADR 0062).

  ## One heavy solve at a time

  A solver is a memory- and CPU-heavy OS process, and the workspace it runs in is small. The
  supervisor therefore allows `max_heavy_sessions` live sessions (config key `:planning`,
  default 1). The limit is enforced where it cannot race: each session claims a heavy slot in
  `Planning.Registry` from its own `init/1`, so two concurrent `start_session/1` calls cannot
  both win the last slot. A full house is `{:error, :heavy_solve_busy}` and nothing is
  started.
  """

  use Supervisor

  alias AshEnterprise.Planning.SolverSession

  @sessions __MODULE__.Sessions

  @doc "The `Task.Supervisor` the sessions' await and cancel tasks run under."
  @spec task_supervisor() :: atom()
  def task_supervisor, do: AshEnterprise.Planning.TaskSupervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  # The sessions, and beside them the supervisor of the tasks they start. Those are not the
  # application's `TaskSupervisor`: a session shuts its own down when it stops (see
  # `SolverSession.terminate/2`), and nothing else shares them.
  @impl true
  def init(_arg) do
    Supervisor.init(
      [
        {DynamicSupervisor, name: @sessions, strategy: :one_for_one},
        {Task.Supervisor, name: task_supervisor()}
      ],
      strategy: :one_for_one
    )
  end

  @doc """
  Starts the session for one resolved run (see `SolverSession.start_run/1`, the public door).

  `{:error, :heavy_solve_busy}` when no heavy slot is free; `{:error, {:already_running, pid}}`
  when a session for the run is live on this node.
  """
  @spec start_session(keyword()) ::
          {:ok, pid()} | {:error, :heavy_solve_busy | {:already_running, pid()} | term()}
  def start_session(opts) do
    case DynamicSupervisor.start_child(@sessions, {SolverSession, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_running, pid}}
      {:error, {:shutdown, :heavy_solve_busy}} -> {:error, :heavy_solve_busy}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "How many solver sessions are live under this supervisor."
  @spec active_count() :: non_neg_integer()
  def active_count, do: DynamicSupervisor.count_children(@sessions).active
end
