defmodule AshEnterprise.Accounts.Preparations.FilterBusinessUnitSubtree do
  @moduledoc """
  Narrows a business-unit read to one node and everything beneath it.

  This is the `Deep` access level expressed as a query: resolve the given node's
  materialized `path`, then prefix-match it. Two queries total, regardless of how
  deep or wide the subtree is.

  Used by `AshEnterprise.Security.ActorContext` to build `bu_subtree_ids` once per
  request, so policy checks can compare against a precomputed set instead of
  querying per row.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    business_unit_id = Ash.Query.get_argument(query, :business_unit_id)

    root =
      AshEnterprise.Accounts.BusinessUnit
      |> Ash.Query.filter(id == ^business_unit_id)
      |> Ash.Query.select([:path])
      |> Ash.read_one(authorize?: false, tenant: query.tenant)

    case root do
      {:ok, %{path: prefix}} ->
        # `like/2` (from ash_postgres) compiles straight to SQL LIKE, so
        # 'prefix%' can use business_units_org_path_prefix_index, which is
        # declared with text_pattern_ops for exactly this.
        #
        # Ash core also has `string_starts_with/2`, which is portable across data
        # layers but does not reliably produce an index-usable predicate -- and
        # the entire premise of the materialized path is that this comparison is
        # indexed. Portability is the wrong trade here.
        #
        # No escaping needed: `path` is built from UUIDs and slashes only, so it
        # cannot contain LIKE metacharacters. If that ever changes, escape
        # `%`, `_` and `\` before interpolating.
        Ash.Query.filter(query, like(path, ^(prefix <> "%")))

      {:ok, nil} ->
        # An unknown root yields an empty subtree rather than an error: callers
        # are usually resolving an actor's business unit, and a missing one must
        # grant nothing rather than blow up mid-request.
        Ash.Query.filter(query, false)

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end
end
