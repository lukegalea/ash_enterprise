defmodule AshEnterprise.Quality.Changes.AddCase do
  @moduledoc "Appends the `case` argument to a draft suite's cases."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :case) do
      nil ->
        changeset

      new ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :cases,
          (changeset.data.cases || []) ++ [new]
        )
    end
  end
end
