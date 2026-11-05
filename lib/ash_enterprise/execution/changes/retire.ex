defmodule AshEnterprise.Execution.Changes.Retire do
  @moduledoc "A manifest's `supersede`: moves it to the state named by its `to` argument."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: AshStateMachine.transition_state(changeset, Ash.Changeset.get_argument(changeset, :to))
end
