defmodule AshEnterprise.Planning.Registry do
  @moduledoc """
  Names the live `AshEnterprise.Planning.SolverSession` processes (ADR 0062), one per run id.

  A `:unique` `Registry` under this module's own name, started by the application
  supervisor as `AshEnterprise.Planning.Registry`. Two kinds of key live in it:

    * `{:run, run_id}`: the session serving that run. A second session for the same run is
      refused by the registry itself (`{:already_started, pid}`), which is what keeps a
      restart or a double-enqueued job from putting two solvers behind one run.
    * `{:heavy_slot, n}`: one entry per heavy-solve slot a session holds. The
      heavy-solve limit (`SessionSupervisor`) is "how many `n` are free", and claiming one is
      a unique-key registration: atomic, and released by the registry the instant the owning
      session dies, so a crashed session can never leak a slot.

  The registry is **local** to this BEAM. Cross-node truth is the run row's lease
  (`lease_epoch`/`lease_expires_at`), never this table.
  """

  @doc false
  def child_spec(_arg), do: Registry.child_spec(keys: :unique, name: __MODULE__)

  @doc "The `:via` name of the session serving `run_id`."
  @spec via(Ecto.UUID.t()) :: {:via, Registry, {module(), {:run, Ecto.UUID.t()}}}
  def via(run_id), do: {:via, Registry, {__MODULE__, {:run, run_id}}}

  @doc "The live session for `run_id` on this node, if any."
  @spec lookup(Ecto.UUID.t()) :: {:ok, pid()} | :error
  def lookup(run_id) do
    case Registry.lookup(__MODULE__, {:run, run_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Claims one of `max` heavy-solve slots for the calling process, on behalf of `run_id`.

  `{:error, :heavy_solve_busy}` when every slot is held. The slot is released when the
  caller exits.
  """
  @spec claim_heavy_slot(Ecto.UUID.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :heavy_solve_busy}
  def claim_heavy_slot(run_id, max) when is_integer(max) and max > 0 do
    Enum.find_value(0..(max - 1), {:error, :heavy_solve_busy}, fn slot ->
      case Registry.register(__MODULE__, {:heavy_slot, slot}, run_id) do
        {:ok, _owner} -> {:ok, slot}
        {:error, {:already_registered, _pid}} -> nil
      end
    end)
  end

  @doc "How many heavy slots are held right now."
  @spec heavy_slots_in_use() :: non_neg_integer()
  def heavy_slots_in_use do
    Registry.select(__MODULE__, [{{{:heavy_slot, :_}, :_, :_}, [], [true]}]) |> length()
  end
end
