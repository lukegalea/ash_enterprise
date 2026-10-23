defmodule AshEnterprise.Finance.Declarations do
  @moduledoc """
  The BIZEV declarations for the household finance store (PROD-12): one
  source, Luke's Tiller sheet, its two tabs as streams, and the four
  mappings that turn a row's observation into a ledger event.

  The Spark DSL host, deliberately not the Ash domain (a module carries one
  Spark DSL; `AshEnterprise.Finance` is the domain). `AshEnterprise.Finance.install!/0`
  publishes each mapping as a content-hashed `AshEnterprise.Finance.MappingVersion`
  and activates it; every ledger row's `provenance` names the version that
  produced it, so a change to a mapping is visible on the rows it made.

  ## What the mappings read

  Not the raw row: the observation `AshEnterprise.Finance.Tiller.Rows`
  normalizes from it (dates as dates, amounts as `AshMoney` in the
  account's declared currency) and `AshEnterprise.Finance.Tiller.Derivation`
  shapes per kind. The raw row lands sealed in the raw layer as it was read.

  ## What the events carry

  The mapped fields below, sealed under the linked account's erasure scope
  before they are recorded (`AshEnterprise.Finance.Recorder`): the ledger is
  append-only, so sealing is what lets a shred reach it. Region `:ca`: the
  household is Canadian, and a region is permanent per row.
  """

  use AshDiscreteBusinessEvents, domains: [AshEnterprise.Finance]

  business_events do
    source :tiller do
      adapter(AshEnterprise.Finance.Tiller.Adapter)
      auth(:nango, provider: "google-sheet")
      region(:ca)

      stream(:transactions, select: "the Transactions tab")
      stream(:balance_history, select: "the Balance History tab")
    end

    # A transaction as Tiller has it now: first sight, a reappearance, or a
    # correction of a posting field (superseding the previous post).
    mapping :"transaction.posted" do
      source {:tiller, :transactions}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:posted_on, from: "posted_on", type: :date)
      map(:amount, from: "amount", type: AshMoney.Types.Money)
      map(:description, from: "description", type: :string)
      map(:full_description, from: "full_description", type: :string)
      map(:category, from: "category", type: :string)
      map(:account, from: "account", type: :string)
      map(:account_mask, from: "account_mask", type: :string)
      map(:institution, from: "institution", type: :string)
      map(:account_id, from: "account_id", type: :string)
      map(:transaction_id, from: "transaction_id", type: :string)
      map(:feed, from: "feed", type: :string)
      map(:merchant_name, from: "merchant_name", type: :string)
      map(:category_hint, from: "category_hint", type: :string)
      map(:note, from: "note", type: :string)
      map(:tags, from: "tags", type: :string)
      map(:categorized_by, from: "categorized_by", type: :string)
      map(:date_added, from: "date_added", type: :date)

      constant(:source_system, value: "tiller")
    end

    # The category changed, in Tiller (by hand or by AutoCat).
    mapping :"transaction.recategorized" do
      source {:tiller, :transactions}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:category, from: "category", type: :string)
      map(:previous_category, from: "previous_category", type: :string)
      map(:categorized_by, from: "categorized_by", type: :string)
      map(:transaction_id, from: "transaction_id", type: :string)

      constant(:source_system, value: "tiller")
    end

    # The row is no longer in the sheet.
    mapping :"transaction.removed" do
      source {:tiller, :transactions}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:posted_on, from: "posted_on", type: :date)
      map(:transaction_id, from: "transaction_id", type: :string)

      constant(:source_system, value: "tiller")
    end

    # One Balance History row: what the institution said the balance was.
    mapping :"balance.observed" do
      source {:tiller, :balance_history}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:observed_on, from: "observed_on", type: :date)
      map(:balance, from: "balance", type: AshMoney.Types.Money)
      map(:account, from: "account", type: :string)
      map(:account_mask, from: "account_mask", type: :string)
      map(:institution, from: "institution", type: :string)
      map(:account_id, from: "account_id", type: :string)

      constant(:source_system, value: "tiller")
    end
  end

  @kinds [
    :"transaction.posted",
    :"transaction.recategorized",
    :"transaction.removed",
    :"balance.observed"
  ]

  @doc "The event kinds the finance store records, in declaration order."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds
end
