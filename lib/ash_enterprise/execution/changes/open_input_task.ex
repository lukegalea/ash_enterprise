defmodule AshEnterprise.Execution.Changes.OpenInputTask do
  @moduledoc """
  On `dispatch`: a question an agent handed on (`AshEnterprise.Execution.HumanInput`)
  gets its task, in the same transaction, so the invocation is never `dispatched` with
  nobody asked.

  It delegates to `AshBpmn.Changes.RequireApproval`, the engine's standalone-task change,
  as `AshEnterprise.Execution.Changes.OpenResolutionTask` does, with the static key
  `"invocation.input"`: one live task per row. The candidate is the person the run acts
  for, the invocation's owner (for an automation principal, the person it acts for):
  the agent asks the person who asked it. The task is due, and expires, when the
  dispatch's deadline passes, so nobody answers a question the run no longer waits for.
  No `on_complete`: the `:collect_input` trigger applies the answer.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.HumanInput

  @impl true
  def change(changeset, _opts, context) do
    if Ash.Changeset.get_argument(changeset, :effect_system) == HumanInput.effect_system() do
      Ash.Resource.Change.change(
        AshBpmn.Changes.RequireApproval,
        changeset,
        [
          key: HumanInput.key(),
          name: "Answer an agent's question",
          outcomes: [:answered],
          candidates: [%{"kind" => "user", "of" => "subject.owner_id"}],
          due_in: HumanInput.answer_within(),
          expire_in: HumanInput.answer_within()
        ],
        context
      )
    else
      changeset
    end
  end
end
