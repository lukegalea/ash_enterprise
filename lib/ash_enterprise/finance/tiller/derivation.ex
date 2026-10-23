defmodule AshEnterprise.Finance.Tiller.Derivation do
  @moduledoc """
  What a new version of a sheet row means, as ledger events: pure functions
  from the row's previous and current observations (normalized by
  `AshEnterprise.Finance.Tiller.Rows`) to the event kinds they imply and the
  observation payload each kind's mapping reads
  (`AshEnterprise.Finance.Declarations`). No reads, no clock: the instant a
  change was seen is an input.

  ## Transactions

  | Previous | Current | Events |
  |---|---|---|
  | none, or removed | present | `transaction.posted` |
  | present | removed from the sheet | `transaction.removed` |
  | present | present, category changed | `transaction.recategorized` |
  | present | present, a posting field changed | `transaction.posted` again, superseding the last one (BIZEV-9) |
  | present | present, nothing tracked changed | none |

  The **category** fields are `category` (and `categorized_by`,
  `categorized_on`, `category_hint`, which change with it and mean nothing
  without it). Everything else Tiller says about the transaction is a
  **posting** field. A row whose category and amount both changed records a
  superseding post and a recategorization.

  A recategorization's `occurred_at` is Tiller's `Categorized Date` when that
  moved with the category, else the instant the change was seen. A
  removal's is the instant it was seen missing.

  ## Balances

  A new balance row records `balance.observed` at its date and time. A
  balance row that changed records it again, superseding the last. A balance
  row that disappears records nothing: a statement that was never true is a
  correction for a reconciliation to notice, not a fact.
  """

  @category_fields ~w(category categorized_by categorized_on category_hint)

  @typedoc "An event to record: its kind, the payload its mapping reads, and whether it supersedes."
  @type event :: %{kind: atom(), payload: map(), supersedes?: boolean()}

  @doc """
  The events a transaction row's new version implies. `previous` and
  `current` are normalized observations, or `:removed` (`previous` may be
  `nil`: first sight). `seen_at` is the step's observation instant.
  """
  @spec transaction(map() | :removed | nil, map() | :removed, DateTime.t()) :: [event()]
  def transaction(previous, :removed, seen_at) when is_map(previous) do
    [
      %{
        kind: :"transaction.removed",
        payload: %{
          "occurred_at" => seen_at,
          "posted_on" => previous["posted_on"],
          "transaction_id" => previous["transaction_id"]
        },
        supersedes?: false
      }
    ]
  end

  def transaction(_previous, :removed, _seen_at), do: []

  def transaction(previous, current, _seen_at) when previous in [nil, :removed] do
    [%{kind: :"transaction.posted", payload: current, supersedes?: previous == :removed}]
  end

  def transaction(previous, current, seen_at) do
    posted =
      if Map.drop(previous, @category_fields) != Map.drop(current, @category_fields),
        do: [%{kind: :"transaction.posted", payload: current, supersedes?: true}],
        else: []

    recategorized =
      if previous["category"] != current["category"],
        do: [
          %{
            kind: :"transaction.recategorized",
            payload: %{
              "occurred_at" => recategorized_at(previous, current, seen_at),
              "category" => current["category"],
              "previous_category" => previous["category"],
              "categorized_by" => current["categorized_by"],
              "transaction_id" => current["transaction_id"]
            },
            supersedes?: false
          }
        ],
        else: []

    posted ++ recategorized
  end

  @doc "The events a balance row's new version implies (see the moduledoc)."
  @spec balance(map() | :removed | nil, map() | :removed) :: [event()]
  def balance(_previous, :removed), do: []

  def balance(previous, current) when previous in [nil, :removed],
    do: [%{kind: :"balance.observed", payload: current, supersedes?: false}]

  def balance(previous, current) do
    if previous == current,
      do: [],
      else: [%{kind: :"balance.observed", payload: current, supersedes?: true}]
  end

  # Tiller's Categorized Date is a date. When it moved with the category, the
  # change is placed at its start; when it did not (a category edited by
  # hand, which Tiller does not date), or it would be in the future, the
  # instant the change was seen is the honest one.
  defp recategorized_at(previous, %{"categorized_on" => %Date{} = on}, seen_at) do
    at = on |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> Map.put(:microsecond, {0, 6})

    if previous["categorized_on"] != on and DateTime.compare(at, seen_at) != :gt,
      do: at,
      else: seen_at
  end

  defp recategorized_at(_previous, _current, seen_at), do: seen_at
end
