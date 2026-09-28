defmodule AshEnterprise.Zones.Jurisdiction do
  @moduledoc """
  Jurisdiction codes, and the one question the admission rule asks of them:
  *does this zone lie inside that jurisdiction?*

  Codes are ISO 3166: a country (`"CA"`, ISO 3166-1 alpha-2) or a subdivision of
  one (`"CA-ON"`, ISO 3166-2). A standard code is used rather than a local
  spelling because containment has to be computable: a zone in `"CA-ON"` lies
  inside `"CA"`, so it satisfies data restricted to Canada, and it does not lie
  inside `"US"`.

  Containment is read from the code alone — a subdivision lies inside its own
  country and nothing else. Supranational restrictions ("EU only") are not
  representable yet; a zone that needs one should declare it as a list of
  countries when the need is real.
  """

  @pattern ~r/\A[A-Z]{2}(-[A-Z0-9]{1,3})?\z/

  @doc "The pattern a jurisdiction code must match. Used as an attribute constraint."
  def pattern, do: @pattern

  @doc """
  Whether `code` is a well-formed ISO 3166-1 alpha-2 or ISO 3166-2 code.

      iex> AshEnterprise.Zones.Jurisdiction.valid?("CA-ON")
      true
      iex> AshEnterprise.Zones.Jurisdiction.valid?("ON-CA")
      true
      iex> AshEnterprise.Zones.Jurisdiction.valid?("ontario")
      false

  The second example is well-formed but is not a subdivision of Canada — it
  reads as country `ON` — which is why codes are written country first.
  """
  def valid?(code) when is_binary(code), do: Regex.match?(@pattern, code)
  def valid?(_), do: false

  @doc """
  Whether a place in jurisdiction `inner` lies inside jurisdiction `outer`.

      iex> AshEnterprise.Zones.Jurisdiction.within?("CA-ON", "CA")
      true
      iex> AshEnterprise.Zones.Jurisdiction.within?("CA-ON", "CA-ON")
      true
      iex> AshEnterprise.Zones.Jurisdiction.within?("CA", "CA-ON")
      false
      iex> AshEnterprise.Zones.Jurisdiction.within?("CA-ON", "US")
      false
  """
  def within?(inner, outer) when is_binary(inner) and is_binary(outer) do
    inner == outer or String.starts_with?(inner, outer <> "-")
  end
end
