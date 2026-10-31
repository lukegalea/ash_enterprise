defmodule AshEnterprise.Execution.Changes.FromRun do
  @moduledoc """
  A step takes its owner and its erasure scope from its run, which the run's
  `record_step` hands to `append` in the changeset context (`ash_agent.run`). A step with
  no run in hand is refused: only the run writes its journal.

  It runs in `change/3`, before `AshEnterprise.Erasure.Changes.SealUnderScope` seals
  `parts` under the scope set here.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case get_in(changeset.context, [:ash_agent, :run]) do
      %{id: id, owner_id: owner_id, erasure_scope_id: scope_id} ->
        if Ash.Changeset.get_attribute(changeset, :run_id) == id do
          Ash.Changeset.force_change_attributes(changeset, %{
            owner_id: owner_id,
            erasure_scope_id: scope_id
          })
        else
          Ash.Changeset.add_error(changeset,
            field: :run_id,
            message: "is not the run recording it"
          )
        end

      _no_run ->
        Ash.Changeset.add_error(changeset, field: :run_id, message: "only its run appends a step")
    end
  end
end
