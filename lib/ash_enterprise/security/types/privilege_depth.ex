defmodule AshEnterprise.Security.Types.PrivilegeDepth do
  @moduledoc """
  How far a granted privilege reaches. The `depth` in `(role, privilege, depth)`.

  A **total order** — each level subsumes everything below it, which is what makes
  the model a pure union of grants rather than a set of overlapping special cases:

      :global ⊃ :deep ⊃ :local ⊃ :basic ⊃ (nothing)

  | Here | Dataverse API | Admin UI label | Reaches |
  |---|---|---|---|
  | `:basic` | `Basic` | User | Records I own, my teams own, or that are shared with me |
  | `:local` | `Local` | Business Unit | Records owned by my business unit |
  | `:deep` | `Deep` | Parent: Child Business Unit | My business unit and every unit beneath it |
  | `:global` | `Global` | Organization | Every record in the tenant |

  The UI labels are worth keeping in view: administrators say "Parent: Child
  Business Unit" and developers say `Deep`, and the mismatch is a reliable source
  of misconfigured roles.

  ## On the underlying integers

  The **names** Basic/Local/Deep/Global are verified — they are stated directly in
  the `privilege` table's own column descriptions (`canbebasic`: *"whether the
  privilege applies to the user, the user's team, or objects shared by the
  user"*, `canbedeep`: *"...child business units..."*, and so on).

  The **numeric** values commonly cited as 0/1/2/3 are **not** verified; the
  Microsoft page documenting the `PrivilegeDepth` enum returned 404 during
  research. So this type stores atoms, not integers. If you later need
  wire-compatibility with a real Dataverse instance, confirm the numbers first and
  add an explicit mapping rather than assuming the ordinal positions here match.
  """

  use Ash.Type.Enum,
    values: [
      basic: "User",
      local: "Business Unit",
      deep: "Parent: Child Business Unit",
      global: "Organization"
    ]

  @order %{basic: 0, local: 1, deep: 2, global: 3}

  @doc """
  Compares two depths. Useful for "does this grant already cover that one?".

      iex> AshEnterprise.Security.Types.PrivilegeDepth.covers?(:deep, :local)
      true
      iex> AshEnterprise.Security.Types.PrivilegeDepth.covers?(:local, :deep)
      false
  """
  def covers?(granted, required)
      when is_map_key(@order, granted) and is_map_key(@order, required) do
    @order[granted] >= @order[required]
  end

  @doc "Every depth that a grant at `depth` also satisfies, widest first."
  def implied_by(depth) when is_map_key(@order, depth) do
    @order
    |> Enum.filter(fn {_name, rank} -> rank <= @order[depth] end)
    |> Enum.sort_by(fn {_name, rank} -> -rank end)
    |> Enum.map(fn {name, _rank} -> name end)
  end

  @doc "Ranks, for sorting and comparison. Internal ordering only — not a wire format."
  def rank(depth) when is_map_key(@order, depth), do: @order[depth]
end
