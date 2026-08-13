defmodule AshEnterprise.Accounts.Changes.MaintainBusinessUnitPath do
  @moduledoc """
  Maintains `path` and `depth` on `AshEnterprise.Accounts.BusinessUnit`.

  `path` is a materialized ancestor chain that turns "my business unit and
  everything beneath it" — the `Deep` access level — into an indexed prefix
  match instead of a recursive query. See the resource's moduledoc for why that
  matters.

  Two cases:

    * **Create** — derive the path from the parent's path, or start a new root.
    * **Update that reparents** — recompute this node's path, then rewrite the
      whole subtree, inside the same transaction.

  The subtree rewrite is a single `UPDATE ... WHERE path LIKE 'old%'` rather than
  a load-and-save loop: a reorganization can move thousands of nodes, and doing
  it row by row through Ash actions would be both slow and noisy in the audit
  log for no benefit. The tradeoff is that the subtree rewrite is not itself
  audited per row — the reparenting of the moved node is, and that is the
  decision a human actually made.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&set_path/1)
    |> Ash.Changeset.after_action(&rewrite_subtree/2)
  end

  # --- path derivation --------------------------------------------------------

  defp set_path(changeset) do
    parent_id = Ash.Changeset.get_attribute(changeset, :parent_business_unit_id)

    case fetch_parent_path(changeset, parent_id) do
      {:ok, parent_path} ->
        id = Ash.Changeset.get_attribute(changeset, :id) || Ash.UUID.generate()

        path = "#{parent_path}#{id}/"
        # Depth is the number of ids in the path, minus this one.
        depth = length(String.split(path, "/", trim: true)) - 1

        changeset
        |> Ash.Changeset.force_change_attribute(:id, id)
        |> Ash.Changeset.force_change_attribute(:path, path)
        |> Ash.Changeset.force_change_attribute(:depth, depth)
        |> stash_old_path()

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp fetch_parent_path(_changeset, nil), do: {:ok, "/"}

  defp fetch_parent_path(changeset, parent_id) do
    parent =
      AshEnterprise.Accounts.BusinessUnit
      |> Ash.Query.filter(id == ^parent_id)
      |> Ash.Query.select([:id, :path])
      |> Ash.read_one(
        # The parent lookup is a structural read needed to compute a derived
        # column. Authorization for the write itself is enforced by the action's
        # policies; re-authorizing this read would forbid creating a child under
        # a business unit the actor can write to but not read.
        authorize?: false,
        tenant: changeset.tenant
      )

    case parent do
      {:ok, nil} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :parent_business_unit_id,
           message: "parent business unit does not exist in this tenant"
         )}

      {:ok, %{path: parent_path, id: parent_id}} ->
        guard_against_cycle(changeset, parent_path, parent_id)

      {:error, error} ->
        {:error, error}
    end
  end

  # A business unit cannot be moved beneath its own descendant. Without this the
  # subtree is detached from the root and becomes invisible to every Deep check —
  # a silent, total loss of access to those records.
  defp guard_against_cycle(changeset, parent_path, parent_id) do
    id = changeset.data && Map.get(changeset.data, :id)

    cond do
      is_nil(id) ->
        {:ok, parent_path}

      id == parent_id ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :parent_business_unit_id,
           message: "a business unit cannot be its own parent"
         )}

      String.contains?(parent_path, "/#{id}/") ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :parent_business_unit_id,
           message: "cannot move a business unit beneath one of its own descendants"
         )}

      true ->
        {:ok, parent_path}
    end
  end

  defp stash_old_path(changeset) do
    case changeset.data do
      %{path: old_path} when is_binary(old_path) ->
        Ash.Changeset.put_context(changeset, :old_business_unit_path, old_path)

      _ ->
        changeset
    end
  end

  # --- subtree rewrite --------------------------------------------------------

  defp rewrite_subtree(changeset, record) do
    old_path = changeset.context[:old_business_unit_path]

    if is_binary(old_path) and old_path != record.path do
      do_rewrite_subtree(old_path, record, depth_of(old_path))
    end

    {:ok, record}
  end

  defp do_rewrite_subtree(old_path, record, old_depth) do
    # Descendants only -- the moved node already has its new path.
    #
    # Every descendant shifts by the SAME depth delta, because the subtree's
    # internal shape does not change. So depth is `depth + delta` rather than
    # recomputed per row from the new path, which keeps this a single arithmetic
    # update instead of string surgery repeated for every row.
    delta = record.depth - old_depth

    AshEnterprise.Repo.query!(
      """
      UPDATE business_units
      SET path = $2::text || substring(path from $3::int),
          depth = depth + $4::int
      WHERE organization_id = $5::uuid
        AND path LIKE $1::text || '%'
        AND path <> $1::text
      """,
      [
        old_path,
        record.path,
        # Postgres cannot infer parameter types inside substring(), so every
        # placeholder here is cast explicitly. Without the ::int, Postgrex is told
        # to encode this integer as text and fails with
        # "expected a binary, got 113".
        byte_size(old_path) + 1,
        delta,
        Ecto.UUID.dump!(record.organization_id)
      ]
    )
  end

  # "/a/b/c/" -> 2. The root is depth 0.
  defp depth_of(path) do
    length(String.split(path, "/", trim: true)) - 1
  end
end
