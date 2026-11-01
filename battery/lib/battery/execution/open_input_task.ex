defmodule Battery.Execution.OpenInputTask do
  @moduledoc """
  On `dispatch`: a question handed on (`Battery.Execution.HumanInput`) gets a standalone
  ash_bpmn task in the dispatch's own transaction, through
  `AshBpmn.Changes.RequireApproval` with the static key `"invocation.input"`. Its
  candidate is the invocation's owner, the person the run acts for. No `on_complete`:
  `Battery.Execution.CollectInput` reads the answer off the task.
  """

  use Ash.Resource.Change

  alias Battery.Execution.HumanInput

  @impl true
  def change(changeset, _opts, context) do
    if Ash.Changeset.get_argument(changeset, :effect_system) == HumanInput.effect_system() do
      opts = [
        key: HumanInput.key(),
        name: "Answer an agent's question",
        outcomes: [:answered],
        candidates: [%{"kind" => "user", "of" => "subject.owner_id"}],
        due_in: [days: 7]
      ]

      Ash.Resource.Change.change(AshBpmn.Changes.RequireApproval, changeset, opts, context)
    else
      changeset
    end
  end
end
