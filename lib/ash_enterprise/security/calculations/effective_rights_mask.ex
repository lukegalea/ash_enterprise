defmodule AshEnterprise.Security.Calculations.EffectiveRightsMask do
  @moduledoc """
  The bitwise OR of an access grant's direct and inherited rights masks.

  Computed in Elixir rather than as an Ash expression because the two masks
  overlap: `rights_mask + inherited_rights_mask` is **not** the same as
  `rights_mask ||| inherited_rights_mask` when both carry the same bit. Read + Read
  would sum to 2, which is Write. A share granting read would silently become a
  share granting write.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:rights_mask, :inherited_rights_mask]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      Bitwise.bor(record.rights_mask || 0, record.inherited_rights_mask || 0)
    end)
  end
end
