defmodule AshEnterprise.Quality.Changes.NextVersion do
  @moduledoc """
  Numbers a new suite draft after the latest version of its key in the tenant. Two
  drafts racing for one number collide on the `[:key, :version]` identity; the loser is
  refused, never renumbered silently.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      key = Ash.Changeset.get_attribute(changeset, :key)

      latest =
        changeset.resource
        |> Ash.Query.filter(key == ^key)
        |> Ash.Query.sort(version: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(tenant: changeset.tenant, authorize?: false)

      Ash.Changeset.force_change_attribute(changeset, :version, version_after(latest))
    end)
  end

  defp version_after(nil), do: 1
  defp version_after(%{version: version}), do: version + 1
end
