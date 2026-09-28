defmodule AshEnterprise.Zones.Residency do
  @moduledoc """
  The residency tag: where a piece of data is allowed to be.

  A tag is either `"unrestricted"` or the jurisdiction code the data is
  restricted to (`"CA"`, `"US"`, `"CA-ON"`; see `AshEnterprise.Zones.Jurisdiction`).

  **There is no default.** A missing tag (`nil`) means *nobody has said yet*, which
  is not the same as "unrestricted", and the admission rule refuses it until
  someone tags it. That is what keeps "restricted data never entered this zone"
  a checkable claim rather than an assumption about where the data came from.
  """

  @unrestricted "unrestricted"

  @doc "The tag for data under no residency restriction."
  def unrestricted, do: @unrestricted

  @doc "The pattern a residency tag must match. Used as an attribute constraint."
  def pattern do
    ~r/\A(unrestricted|[A-Z]{2}(-[A-Z0-9]{1,3})?)\z/
  end

  @doc """
  Whether `tag` is a well-formed residency tag. `nil` is not: it is *untagged*.

      iex> AshEnterprise.Zones.Residency.valid?("unrestricted")
      true
      iex> AshEnterprise.Zones.Residency.valid?("US")
      true
      iex> AshEnterprise.Zones.Residency.valid?(nil)
      false
  """
  def valid?(@unrestricted), do: true
  def valid?(tag), do: AshEnterprise.Zones.Jurisdiction.valid?(tag)
end
