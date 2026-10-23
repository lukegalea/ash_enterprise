defmodule AshEnterprise.Finance.TillerSource do
  @moduledoc """
  One Tiller sheet, read through one of the actor's own Google Sheets linked
  accounts (PROD-12): which spreadsheet and tabs, which currency each bank
  account is in, and how the last sync went. The sync's record, so its
  state is data (BIZEV §2.3), never job args.

  ## Currencies are declared, never guessed

  Tiller's Transactions and Balance History have no currency column, and
  Luke holds CAD and USD accounts. Every amount is recorded as `AshMoney` in
  its account's currency, so each account's currency is a statement made
  here: `default_currency` for every account not listed, and
  `account_currencies` (Tiller `Account ID` → ISO code) for the rest. With
  no default, an account nobody declared stops the sync
  (`:currency_undeclared`) rather than landing amounts in a guessed currency.
  Declare before the first sync: a declaration changed later applies to the
  rows that change after it, not to events already recorded.

  ## Choices

    * **User-owned and owner-only** (`AshEnterprise.Security.Privilege.owner_only?/1`):
      the sheet is one person's finances.
    * **`spreadsheet_id` is `sensitive?`**: it names a person's sheet, so the
      audit log records it as `nil`.
    * `imported_at` marks the end of the first complete pass, the historical
      backfill (ADR 0049): events recorded before it carry
      `context["import"] = true`.
    * `archival?: false`: a soft-deleted row would keep the linked account's
      identity occupied.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Finance,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "finance_tiller_sources"
    repo AshEnterprise.Repo

    references do
      reference :linked_account, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :spreadsheet_id, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints max_length: 128, match: ~r/\A[A-Za-z0-9_-]+\z/
      description "The Google spreadsheet id (from the sheet's URL). Never audited."
    end

    attribute :transactions_range, :string do
      allow_nil? false
      public? true
      default "Transactions"
      constraints max_length: 128
      description "The tab (A1 range) holding Tiller's Transactions."
    end

    attribute :balances_range, :string do
      allow_nil? false
      public? true
      default "Balance History"
      constraints max_length: 128
      description "The tab (A1 range) holding Tiller's Balance History."
    end

    attribute :default_currency, :string do
      public? true
      constraints match: ~r/\A[A-Z]{3}\z/

      description "The currency of every account not in account_currencies. Nil: every account must be declared."
    end

    attribute :account_currencies, :map do
      allow_nil? false
      public? true
      default %{}
      description "Tiller Account ID → ISO 4217 code, for accounts not in the default currency."
    end

    attribute :imported_at, :utc_datetime_usec do
      public? true
      description "When the first complete pass (the historical import) finished."
    end

    attribute :last_synced_at, :utc_datetime_usec do
      public? true
      description "When a sync step last completed."
    end

    attribute :last_summary, :map do
      public? true
      description "The last step's counts (structural only: no amounts, no payees)."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :linked_account, AshEnterprise.Integration.LinkedAccount do
      public? true
      attribute_public? true
      allow_nil? false
      domain AshEnterprise.Integration
      description "The Google Sheets linked account the sheet is read through."
    end
  end

  identities do
    identity :unique_linked_account, [:linked_account_id]
  end

  validations do
    validate {AshEnterprise.Finance.Validations.Currencies, []},
      on: [:create, :update]
  end

  actions do
    defaults [:read]

    create :configure do
      description """
      Name the Tiller sheet one of the actor's own Google Sheets linked
      accounts reads, and the currencies of its accounts. The owner is the
      acting human; it is not an input.
      """

      accept [
        :linked_account_id,
        :spreadsheet_id,
        :transactions_range,
        :balances_range,
        :default_currency,
        :account_currencies
      ]

      change AshEnterprise.Integration.Changes.OwnedByActor
      change AshEnterprise.Finance.Changes.RequireOwnSheetAccount
    end

    update :declare_currencies do
      description "Declare the default currency and the accounts held in another."
      accept [:default_currency, :account_currencies]
    end

    update :record_run do
      description """
      Persist a completed step: when, its counts, and — the first time a
      step covers the whole sheet — when the import finished. Called by the
      sync step as the account's owner.
      """

      accept [:last_synced_at, :last_summary, :imported_at]
    end

    read :for_linked_account do
      description "The Tiller sheet one linked account reads, if one is configured."
      get? true
      argument :linked_account_id, :uuid, allow_nil?: false
      filter expr(linked_account_id == ^arg(:linked_account_id))
    end
  end

  code_interface do
    define :configure
    define :declare_currencies
    define :record_run
    define :for_linked_account, args: [:linked_account_id], not_found_error?: false
  end

  @doc "The declared currency of a row's account, or nil."
  @spec currency_for(t :: struct(), String.t() | nil) :: String.t() | nil
  def currency_for(%__MODULE__{} = source, account_ref) do
    Map.get(source.account_currencies || %{}, account_ref) || source.default_currency
  end
end
