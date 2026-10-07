defmodule AshEnterprise.Agents.Changes.SpawnOmpProcess do
  @moduledoc """
  Binds the `:start` action to the bridge: a committed run gets its OMP
  process.

  In `after_transaction`, not `after_action`: the session GenServer reads the
  run and its workspace through its own connection, which must see the commit
  — spawning inside the transaction races it (and under the SQL sandbox would
  join it). This is the discipline rule that external calls belong in
  `before_transaction`/`after_transaction`.

  A clean spawn failure (no omp binary) is not an action failure:
  `OmpSession.start_run/1` has already failed the run and recorded the reason
  on its transcript, and the tool caller gets that run back — the resource
  row, not a raised error, is the record of what happened.
  """

  use Ash.Resource.Change

  require Logger

  alias AshEnterprise.Agents.OmpSession

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, run} ->
        case OmpSession.start_run(run) do
          {:ok, _pid} ->
            {:ok, run}

          {:error, :omp_binary_missing} ->
            {:ok, run}

          {:error, other} ->
            # The run row committed; the bridge could not take it. The run
            # stays :running for an operator to cancel — louder than silently
            # failing the action after the fact.
            Logger.error(
              "run #{run.id} committed but the OMP process could not start: #{inspect(other)}"
            )

            {:ok, run}
        end

      _changeset, {:error, _} = error ->
        error
    end)
  end
end
