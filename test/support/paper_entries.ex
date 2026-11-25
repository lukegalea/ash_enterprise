defmodule AshEnterprise.Test.PaperEntries do
  @moduledoc """
  SYNTHETIC rows for the `activity_summary` kind
  (`AshEnterprise.Test.Paper.ActivitySummary`): seeded as a person's own
  `AshEnterprise.Test.Paper.Entry` rows, which the kind reads back as them, or
  built straight into the source map for fixtures that never issue.

  A row is `{key, "YYYY-MM-DD", "amount", category}`, in CAD unless a fifth
  element names the currency. Nothing here is anyone's data.
  """

  alias AshEnterprise.Test.Paper.{ActivitySummary, Entry}

  @rows [
    {"a", "2025-01-02", "-20", "Groceries"},
    {"b", "2025-03-04", "-5.50", "Groceries"},
    {"c", "2025-06-01", "1000", "Paycheck"},
    {"d", "2025-07-15", "-40", "Hazard"}
  ]

  @doc "The default rows: four CAD entries in 2025, one of them a Hazard."
  @spec rows() :: [tuple()]
  def rows, do: @rows

  @doc "The subject that names `year`."
  @spec subject(integer()) :: map()
  def subject(year \\ 2025), do: %{"year" => year}

  @doc "Seeds `rows` as `person`'s own entries in their tenant; returns the entries."
  @spec seed!(map(), [tuple()]) :: [struct()]
  def seed!(person, rows \\ @rows) do
    user = person.user

    Enum.map(rows, fn row ->
      Entry
      |> Ash.Changeset.for_create(
        :create,
        row
        |> entry()
        |> Map.merge(%{
          owner_id: user.id,
          owner_type: :user,
          owning_user_id: user.id,
          owning_business_unit_id: user.owning_business_unit_id
        }),
        tenant: person.tenant,
        authorize?: false
      )
      |> Ash.create!()
    end)
  end

  @doc """
  Changes `person`'s entries in `category` (`:amount` as a string, or
  `:category`): their rows moved, the way a person's data moves under a draft.
  """
  @spec change!(map(), String.t(), map()) :: :ok
  def change!(person, category, changes) do
    changes =
      Map.new(changes, fn
        {:amount, amount} -> {:amount, Decimal.new(amount)}
        other -> other
      end)

    Entry
    |> Ash.read!(tenant: person.tenant, authorize?: false)
    |> Enum.filter(&(&1.owner_id == person.user.id and &1.category == category))
    |> Enum.each(fn entry ->
      entry
      |> Ash.Changeset.for_update(:update, changes, tenant: person.tenant, authorize?: false)
      |> Ash.update!()
    end)
  end

  @doc "The source map `rows` give for `year`, built without the store."
  @spec source([tuple()], integer()) :: map()
  def source(rows \\ @rows, year \\ 2025),
    do: rows |> Enum.map(&entry/1) |> ActivitySummary.build(year)

  defp entry({_key, on, amount, category}), do: entry({nil, on, amount, category, "CAD"})

  defp entry({_key, on, amount, category, currency}) do
    %{
      on: Date.from_iso8601!(on),
      amount: Decimal.new(amount),
      currency: currency,
      category: category
    }
  end
end
