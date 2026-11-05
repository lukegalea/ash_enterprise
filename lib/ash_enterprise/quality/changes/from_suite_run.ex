defmodule AshEnterprise.Quality.Changes.FromSuiteRun do
  @moduledoc """
  A case result takes its owner from its suite run, which the suite run's `finish`
  hands to `record` in the changeset context (`quality.suite_run`). A result with no
  suite run in hand is refused: only its suite run records it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case get_in(changeset.context, [:quality, :suite_run]) do
      %{id: id, owner_id: owner_id} ->
        if Ash.Changeset.get_attribute(changeset, :suite_run_id) == id,
          do: Ash.Changeset.force_change_attribute(changeset, :owner_id, owner_id),
          else:
            Ash.Changeset.add_error(changeset,
              field: :suite_run_id,
              message: "is not the suite run recording it"
            )

      _none ->
        Ash.Changeset.add_error(changeset,
          field: :suite_run_id,
          message: "only its suite run records a result"
        )
    end
  end
end
