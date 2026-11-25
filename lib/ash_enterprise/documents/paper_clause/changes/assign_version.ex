defmodule AshEnterprise.Documents.PaperClause.Changes.AssignVersion do
  @moduledoc """
  Numbers a draft at the next version within its `(key, locale)` in the
  tenant, the way `AshEnterprise.Quality.Changes.NextVersion` numbers a suite
  within its key. Two drafts racing for one number collide on the
  `(key, locale, version)` identity; the loser is refused, never renumbered
  silently.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      key = Ash.Changeset.get_attribute(changeset, :key)
      locale = Ash.Changeset.get_attribute(changeset, :locale)

      # Every version of the wording, whoever may read it: numbering is the
      # tenant's, not the drafter's view of it.
      latest =
        changeset.resource
        |> Ash.Query.filter(key == ^key and locale == ^locale)
        |> Ash.Query.sort(version: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(tenant: changeset.tenant, authorize?: false)

      Ash.Changeset.force_change_attribute(changeset, :version, version_after(latest))
    end)
  end

  defp version_after(nil), do: 1
  defp version_after(%{version: version}), do: version + 1
end
