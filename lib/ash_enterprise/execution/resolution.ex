defmodule AshEnterprise.Execution.Resolution do
  @moduledoc """
  The task a person settles an invocation's unknown outcome with, and the door they
  decide it through.

  When an outside call's acknowledgement is lost and its target declares no lookup that
  can tell whether it took effect, nobody but a person can. `request_resolution` opens a
  standalone `HumanTask` for the row under the key `"invocation.resolution"`
  (`AshEnterprise.Execution.Changes.OpenResolutionTask`), offered to the tenant's
  administrators. Its outcomes are not approve and reject but what happened:

    * `succeeded`: the effect happened. The invocation succeeds.
    * `failed`: it did not, and should not be tried again. The invocation fails.
    * `retry`: it did not; run it again. The invocation is ready again, with the same
      key and arguments.

  A standalone task stores no declared outcomes, and the board's Complete picker offers
  only the outcomes the checked-in process baselines declare, so neither door offered
  these. `HumanTask.resolve` does: its `outcome` argument is enumerated, so a board
  shows a picker of exactly these three. It accepts only a resolution task, and
  `approve`, `reject` and `complete_task` refuse one, so a resolution can only ever be
  one of the three (`check/2`). The `:apply_resolution` trigger then applies the
  decision (`AshEnterprise.Execution.Changes.ReadResolution`).
  """

  @key "invocation.resolution"
  @outcomes ~w(succeeded failed retry)

  @doc "The standalone task key a resolution task is opened under."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The outcomes a resolution task is decided with."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "Whether `task` is a resolution task."
  @spec task?(struct()) :: boolean()
  def task?(%{node_id: @key, instance_id: nil}), do: true
  def task?(_task), do: false

  @doc """
  Whether `task` may be decided through `door`: `:resolve` (the `HumanTask.resolve`
  action) for a resolution task, any other door (approve, reject, complete, answer) for
  every other task.
  """
  @spec check(struct(), atom()) :: :ok | {:error, String.t()}
  def check(task, :resolve) do
    if task?(task),
      do: :ok,
      else:
        {:error, "only a task settling an unknown outcome is resolved; approve or complete it"}
  end

  def check(task, _door) do
    if task?(task),
      do:
        {:error,
         "this task settles an unknown outcome: resolve it with succeeded, failed or retry"},
      else: :ok
  end
end
