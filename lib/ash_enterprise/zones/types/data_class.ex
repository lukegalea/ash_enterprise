defmodule AshEnterprise.Zones.Types.DataClass do
  @moduledoc """
  How sensitive a piece of data is. One of the two tags every item carries before
  it may enter a zone ([ADR 0042](../../../../docs/adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md));
  the other is its residency restriction (`AshEnterprise.Zones.Residency`).

  A **total order**, least sensitive first:

      :public < :synthetic < :internal < :customer_confidential

  A zone declares a classification *ceiling*; data above the ceiling is refused
  on the way in. `:synthetic` sits above `:public` only because it is ours, not
  the world's — neither needs an authorization to flow anywhere.
  """

  use Ash.Type.Enum,
    values: [
      public: "Public",
      synthetic: "Synthetic",
      internal: "Internal",
      customer_confidential: "Customer confidential"
    ]

  @rank %{public: 0, synthetic: 1, internal: 2, customer_confidential: 3}

  @doc """
  Whether data of class `class` may be held under `ceiling`.

      iex> AshEnterprise.Zones.Types.DataClass.within_ceiling?(:internal, :customer_confidential)
      true
      iex> AshEnterprise.Zones.Types.DataClass.within_ceiling?(:customer_confidential, :internal)
      false
  """
  def within_ceiling?(class, ceiling)
      when is_map_key(@rank, class) and is_map_key(@rank, ceiling) do
    @rank[class] <= @rank[ceiling]
  end
end
