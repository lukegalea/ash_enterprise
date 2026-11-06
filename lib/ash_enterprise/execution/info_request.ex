defmodule AshEnterprise.Execution.InfoRequest do
  @moduledoc """
  An approver asks the requester for more information before deciding (R2 HW-06).

  A reviewer who cannot decide yet answers an invocation's approval task with
  `HumanTask.request_info` and a question, instead of approving or rejecting it. The
  task completes as `request_info`, and the `:apply_decision` trigger applies that
  (`AshEnterprise.Execution.Changes.ReadApproval`): the invocation waits in
  `request_info`, which no claim takes and to which no decision applies, and in the same
  transaction a standalone task opens for the requester under the key
  `"invocation.info"` (`AshEnterprise.Execution.Changes.OpenInfoTask`), due in
  `answer_within/0`.

  The requester answers through `HumanTask.answer`, the door an agent's question is
  answered through too. The `:provide_info` trigger then runs `provide_info`
  (`AshEnterprise.Execution.Changes.ReadInfo`): the invocation is back in
  `awaiting_approval` with a new approval task and a new approval window, and the same
  binding. Only a later approval makes it ready; the fragment checks the binding again
  then. An amendment is not an answer: changing what is asked for is a new request.

  `check/2` keeps the doors apart: only an invocation's approval task asks for more
  information, and an information request is answered only through `answer`.
  """

  alias AshEnterprise.Execution.Approval

  @key "invocation.info"
  @answer_within [days: 7]

  @doc "The standalone task key a request for more information is opened under."
  @spec key() :: String.t()
  def key, do: @key

  @doc "How long the requester has before their answer is due."
  @spec answer_within() :: keyword()
  def answer_within, do: @answer_within

  @doc "Whether `task` asks a requester for more information."
  @spec task?(struct()) :: boolean()
  def task?(%{node_id: @key, instance_id: nil}), do: true
  def task?(_task), do: false

  @doc """
  Whether `task` may be decided through `door`: `:request_info` only on an invocation's
  approval task; an information request only through `:answer`.
  """
  @spec check(struct(), atom()) :: :ok | {:error, String.t()}
  def check(task, :request_info) do
    if approval_task?(task),
      do: :ok,
      else: {:error, "only a request waiting for approval can ask for more information"}
  end

  def check(_task, :answer), do: :ok

  def check(task, _door) do
    if task?(task),
      do: {:error, "this task asks you for more information: answer it"},
      else: :ok
  end

  defp approval_task?(task) do
    key = Approval.key()
    match?(%{node_id: ^key, instance_id: nil}, task)
  end
end
