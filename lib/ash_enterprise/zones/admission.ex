defmodule AshEnterprise.Zones.Admission do
  @moduledoc """
  The admission rule of ADR 0042: may this item enter this zone?

  An item enters zone *Z* iff all of these hold:

    0. `Z`'s declaration has not lapsed (its `review_by` date has not passed);
    1. it carries a data class, and that class is at or below `Z.classification_ceiling`;
    2. it carries a residency tag (untagged data is refused until it is tagged);
    3. its restriction is not among `Z.inadmissible_restrictions` — a restriction
       *inside* an inadmissible one counts, so `"US"` also refuses `"US-NY"`;
    4. its restriction is `"unrestricted"`, or `Z.jurisdiction` lies inside the
       jurisdiction it is restricted to.

  The checks run in that order and the first failure is the reason, so a refusal
  says the most specific thing it can.

  Pure: no queries, no process state, no clock. The caller supplies the zone and,
  to check for a lapsed declaration, the date (`on:`). That keeps it
  usable from an Ash change on the ingest path (`AshEnterprise.Zones.Changes.Admit`),
  from an export script run inside the zone, and from a test, with the same answer.
  """

  alias AshEnterprise.Zones.{Jurisdiction, Residency, Zone}
  alias AshEnterprise.Zones.Types.DataClass

  @typedoc "Anything shaped like a zone declaration."
  @type zone :: %{
          required(:jurisdiction) => String.t(),
          required(:classification_ceiling) => DataClass.t(),
          optional(:inadmissible_restrictions) => [String.t()] | nil,
          optional(:review_by) => Date.t() | nil,
          optional(any()) => any()
        }

  @typedoc "An item's tags. `nil` means untagged."
  @type tags :: %{data_class: DataClass.t() | nil, residency: String.t() | nil}

  @type reason ::
          :declaration_lapsed
          | :untagged_data_class
          | :untagged_residency
          | :invalid_data_class
          | :invalid_residency
          | :above_ceiling
          | :inadmissible_restriction
          | :restriction_unsatisfied

  @doc """
  Checks `tags` against `zone`. Returns `:ok` or `{:error, reason}`.

  Pass `on: date` to refuse everything once the zone's `review_by` has passed.
  `AshEnterprise.Zones.admit/3` always passes today's date.

      iex> zone = %{jurisdiction: "CA-ON", classification_ceiling: :customer_confidential,
      ...>          inadmissible_restrictions: ["US"]}
      iex> AshEnterprise.Zones.Admission.check(zone, %{data_class: :customer_confidential, residency: "CA"})
      :ok
      iex> AshEnterprise.Zones.Admission.check(zone, %{data_class: :internal, residency: "US"})
      {:error, :inadmissible_restriction}
      iex> AshEnterprise.Zones.Admission.check(zone, %{data_class: :internal, residency: nil})
      {:error, :untagged_residency}
  """
  @spec check(zone(), tags(), keyword()) :: :ok | {:error, reason()}
  def check(zone, tags, opts \\ []) do
    class = Map.get(tags, :data_class)
    residency = Map.get(tags, :residency)
    on = Keyword.get(opts, :on)

    with :ok <- check_declaration(zone, on),
         :ok <- check_tags(class, residency) do
      check_against_zone(zone, class, residency)
    end
  end

  defp check_declaration(zone, on) do
    if on && Zone.lapsed?(zone, on), do: {:error, :declaration_lapsed}, else: :ok
  end

  defp check_tags(class, residency) do
    cond do
      is_nil(class) -> {:error, :untagged_data_class}
      is_nil(residency) -> {:error, :untagged_residency}
      DataClass.match(class) == :error -> {:error, :invalid_data_class}
      not Residency.valid?(residency) -> {:error, :invalid_residency}
      true -> :ok
    end
  end

  defp check_against_zone(zone, class, residency) do
    cond do
      not within_ceiling?(class, zone.classification_ceiling) -> {:error, :above_ceiling}
      inadmissible?(zone, residency) -> {:error, :inadmissible_restriction}
      not satisfied?(zone, residency) -> {:error, :restriction_unsatisfied}
      true -> :ok
    end
  end

  @doc "Whether `tags` may enter `zone`."
  @spec admissible?(zone(), tags(), keyword()) :: boolean()
  def admissible?(zone, tags, opts \\ []), do: check(zone, tags, opts) == :ok

  @doc "A sentence explaining a refusal. Carries no data, only the tags' shape."
  @spec describe(reason()) :: String.t()
  def describe(:declaration_lapsed),
    do:
      "cannot be admitted: the zone's declaration is past its review_by date and must be renewed"

  def describe(:untagged_data_class),
    do: "has no data class; untagged data is refused until it is tagged"

  def describe(:untagged_residency),
    do: "has no residency tag; untagged data is refused until it is tagged"

  def describe(:invalid_data_class),
    do: "has a data class that is not one of #{inspect(DataClass.values())}"

  def describe(:invalid_residency),
    do: "has a residency tag that is neither \"unrestricted\" nor an ISO 3166 code"

  def describe(:above_ceiling), do: "is classified above the zone's classification ceiling"

  def describe(:inadmissible_restriction),
    do: "is under a residency restriction this zone declares it cannot hold"

  def describe(:restriction_unsatisfied),
    do: "is restricted to a jurisdiction this zone does not lie inside"

  defp within_ceiling?(class, ceiling) do
    {:ok, class} = DataClass.match(class)
    {:ok, ceiling} = DataClass.match(ceiling)
    DataClass.within_ceiling?(class, ceiling)
  end

  defp inadmissible?(_zone, unrestricted) when unrestricted == "unrestricted", do: false

  defp inadmissible?(zone, restriction) do
    zone
    |> Map.get(:inadmissible_restrictions)
    |> List.wrap()
    |> Enum.any?(&Jurisdiction.within?(restriction, &1))
  end

  defp satisfied?(_zone, unrestricted) when unrestricted == "unrestricted", do: true
  defp satisfied?(zone, restriction), do: Jurisdiction.within?(zone.jurisdiction, restriction)
end
