defmodule AshEnterprise.Execution.Changes.OpenInfoTask do
  @moduledoc """
  On `apply_decision`: when the approver asked for more information
  (`AshEnterprise.Execution.InfoRequest`), the requester gets their task in the same
  transaction, so the invocation never waits in `request_info` with nobody asked.

  The decision is read from the row's latest approval task, the same task
  `AshEnterprise.Execution.Changes.ReadApproval` hands the fragment its outcome from;
  the fragment moves a row answered `request_info` to `request_info` unconditionally,
  so the two agree. Any other decision opens nothing.

  It delegates to `AshBpmn.Changes.RequireApproval`, the engine's standalone-task change,
  as `AshEnterprise.Execution.Changes.OpenInputTask` does, with the static key
  `"invocation.info"`: one live task per row. The candidate is the requester, the
  invocation's owner (for an automation principal, the person it acts for). The task is
  due in `InfoRequest.answer_within/0` and does not expire: the request waits until they
  answer or someone cancels it. No `on_complete`: the `:provide_info` trigger applies
  the answer (`AshEnterprise.Execution.Changes.ReadInfo`).
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Changes.ReadApproval
  alias AshEnterprise.Execution.InfoRequest

  @impl true
  def change(changeset, _opts, context) do
    case ReadApproval.approval_task(changeset.data, changeset.tenant) do
      {:ok, %{status: :completed, outcome: "request_info"}} ->
        Ash.Resource.Change.change(
          AshBpmn.Changes.RequireApproval,
          changeset,
          [
            key: InfoRequest.key(),
            name: "Answer a question about your request",
            outcomes: [:answered],
            candidates: [%{"kind" => "user", "of" => "subject.owner_id"}],
            due_in: InfoRequest.answer_within()
          ],
          context
        )

      _other ->
        changeset
    end
  end
end
