defmodule AshEnterprise.Execution.Recovery do
  @moduledoc """
  What an operator may do about one invocation, by its status: the rules the recovery
  surface (`AshEnterpriseWeb.RecoveryLive`) offers its acts by and the actions refuse by,
  so the page never offers what the action would refuse.

  | Act | Offered when | What it does |
  |---|---|---|
  | settle | the outcome is unknown and a person has been asked (`resolution_requested_at`) | records what happened: it happened, it did not, or it did not and runs again under the same request |
  | rerun | the outcome is known (`succeeded`, `failed`, `cancelled`, `stale`, `rejected`) and the row belongs to no run or process | asks again as a new request, with a new key, linked to this one |
  | cancel | the request has not finished (`requested`, `awaiting_approval`, `request_info`, `ready`, `executing`, `dispatched`) | stops a request that has not run; marks one that is running |

  An unknown outcome is never rerun and never retried as it stands: its effect may have
  happened, and running it again could do it twice. It is settled first, by asking the
  outside system (the `:reconcile` job) or a person.

  A run's tool call and a process's service task are rerun from their run or process,
  which wait on them: a rerun outside them would not wake what waits.
  """

  @known [:succeeded, :failed, :cancelled, :stale, :rejected]
  @unfinished [:requested, :awaiting_approval, :request_info, :ready, :executing, :dispatched]

  @typedoc "Why an act is not offered."
  @type refusal ::
          :outcome_unknown
          | :not_finished
          | :finished
          | :belongs_to_run
          | :belongs_to_process
          | :not_asked_yet
          | :outcome_known
          | :unknown_status

  @doc "The statuses whose outcome is known."
  @spec known() :: [atom()]
  def known, do: @known

  @doc "Whether `invocation` may be rerun as a new request."
  @spec rerun(map()) :: :ok | {:error, refusal()}
  def rerun(%{status: :outcome_unknown}), do: {:error, :outcome_unknown}
  def rerun(%{status: status}) when status in @unfinished, do: {:error, :not_finished}
  def rerun(%{run_id: id}) when is_binary(id), do: {:error, :belongs_to_run}
  def rerun(%{process_instance_id: id}) when is_binary(id), do: {:error, :belongs_to_process}
  def rerun(%{status: status}) when status in @known, do: :ok
  def rerun(_invocation), do: {:error, :unknown_status}

  @doc "Whether `invocation` may be cancelled."
  @spec cancel(map()) :: :ok | {:error, refusal()}
  def cancel(%{status: status}) when status in @unfinished, do: :ok
  def cancel(%{status: :outcome_unknown}), do: {:error, :outcome_unknown}
  def cancel(%{status: status}) when status in @known, do: {:error, :finished}
  def cancel(_invocation), do: {:error, :unknown_status}

  @doc "Whether a person may settle `invocation`'s unknown outcome now."
  @spec settle(map()) :: :ok | {:error, refusal()}
  def settle(%{status: :outcome_unknown, resolution_requested_at: %DateTime{}}), do: :ok
  def settle(%{status: :outcome_unknown}), do: {:error, :not_asked_yet}
  def settle(%{status: status}) when status in @known, do: {:error, :outcome_known}
  def settle(%{status: status}) when status in @unfinished, do: {:error, :not_finished}
  def settle(_invocation), do: {:error, :unknown_status}

  @doc "Why an act is refused, as a sentence."
  @spec explain(refusal()) :: String.t()
  def explain(:outcome_unknown),
    do: "its outcome is unknown: settle what happened first, or it could happen twice"

  def explain(:not_finished), do: "it has not finished"
  def explain(:finished), do: "it has finished; cancelling it would change nothing"
  def explain(:belongs_to_run), do: "it is a tool call of an agent run; recover the run"
  def explain(:belongs_to_process), do: "it is a task of a process; recover the process"
  def explain(:not_asked_yet), do: "the outside system is still being asked what happened"
  def explain(:outcome_known), do: "its outcome is already known"
  def explain(:unknown_status), do: "its status is not one this page knows"
end
