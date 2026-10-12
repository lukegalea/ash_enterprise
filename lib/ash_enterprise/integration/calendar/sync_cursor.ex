defmodule AshEnterprise.Integration.Calendar.SyncCursor do
  @moduledoc """
  Where one calendar's incremental sync stands: one row per (linked account,
  calendar on that account's calendar list).

  Google's events.list sync protocol (public reference, "Synchronize
  resources efficiently"):

    * A pass with no `sync_token` is a **full sync**; a pass with one is
      **incremental**. Either may span pages, chained by `pageToken`.
    * The last page of a pass carries `nextSyncToken`; that becomes
      `sync_token` here (`:complete`), and `page_token` is cleared.
    * Mid-pass, the `nextPageToken` is persisted after each landed page
      (`:page`), so a crashed step resumes where it stopped instead of
      re-fetching the pass.
    * An expired token comes back **410 Gone**. That is answered by the
      explicit `:reset` action — never by silently dropping the token — and
      the next pass is a full sync.

  ## Choices

    * **User-owned**, owner forced to the acting human (the edge's
      `OwnedByActor`): a calendar's sync state belongs to the person whose
      account it is, so Basic depth means "my own cursors".
    * **`calendar_id`, `sync_token`, `page_token` are `sensitive?` and not
      `public?`.** A primary calendar's id is its owner's email address, and
      the tokens are opaque provider state with no business in an API surface,
      the audit `data` or inspect output.
    * **`audit?: false`**: the cursor is machine bookkeeping rewritten on every
      page of every sync; an audit row per page would be noise that also copies
      the tokens into the event log. Resets are still visible on the row
      (`last_reset_at`, `reset_count`).
    * **`archival?: false`, `lifecycle?: false`**: a calendar that leaves the
      calendar list is `:unlist`ed, not soft-deleted, so its row (and therefore
      the cursor id baked into its events' external ids) survives being
      re-added. Unlinking the account deletes its cursors by foreign key.

  The cursor's `id` is also the opaque calendar key in every landed event's
  external id (`AshEnterprise.Canonical.Projections.Calendar.external_id/2`):
  unique per account and calendar, and — unlike the calendar id — carries no
  email address.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration.Calendar,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    audit?: false

  postgres do
    table "integration_calendar_sync_cursors"
    repo AshEnterprise.Repo

    references do
      reference :linked_account, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :calendar_id, :string do
      allow_nil? false
      public? false
      sensitive? true
      constraints max_length: 1024
      description "Google's calendar id (the owner's email for a primary calendar)."
    end

    attribute :sync_token, :string do
      public? false
      sensitive? true
      constraints max_length: 4096

      description "nextSyncToken of the last completed pass. Nil means the next pass is a full sync."
    end

    attribute :page_token, :string do
      public? false
      sensitive? true
      constraints max_length: 4096
      description "nextPageToken of the in-flight pass. Nil when no pass is in flight."
    end

    attribute :listed, :boolean do
      allow_nil? false
      default true
      public? true
      description "Whether the calendar was on the account's calendar list at the last step."
    end

    attribute :last_synced_at, :utc_datetime_usec do
      public? true
      description "When a pass last completed."
    end

    attribute :last_reset_at, :utc_datetime_usec do
      public? true
      description "When the cursor was last reset (410 Gone or an operator reset)."
    end

    attribute :reset_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
      description "How many times the cursor has been reset."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :linked_account, AshEnterprise.Integration.LinkedAccount do
      domain AshEnterprise.Integration
      allow_nil? false
      public? true
      attribute_public? true
      description "The linked account whose calendar this cursor tracks."
    end
  end

  identities do
    identity :unique_calendar, [:linked_account_id, :calendar_id]
  end

  actions do
    defaults [:read]

    read :for_account do
      description "Every cursor of one linked account, in a stable order."

      argument :linked_account_id, :uuid, allow_nil?: false

      filter expr(linked_account_id == ^arg(:linked_account_id))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :track do
      description """
      Start tracking a calendar that appeared on the account's calendar list.
      The owner is the acting human; it is not an input.
      """

      accept [:linked_account_id, :calendar_id]
      change AshEnterprise.Integration.Changes.OwnedByActor
    end

    update :page do
      description "Persist the next page of the in-flight pass, after this page landed."
      accept [:page_token]
    end

    update :complete do
      description "A pass finished: keep its nextSyncToken, clear the page token."

      accept [:sync_token]
      change set_attribute(:page_token, nil)
      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
    end

    update :reset do
      description """
      The explicit sync-reset: forget both tokens so the next pass is a full
      sync. Called on 410 Gone and by `Sync.reset_sync`; never implicit.
      """

      accept []
      change set_attribute(:sync_token, nil)
      change set_attribute(:page_token, nil)
      change set_attribute(:last_reset_at, &DateTime.utc_now/0)
      change atomic_update(:reset_count, expr(reset_count + 1))
    end

    update :unlist do
      description "The calendar left the calendar list (or answered 404): stop syncing it."

      accept []
      change set_attribute(:listed, false)
    end

    update :relist do
      description "The calendar is back on the calendar list."

      accept []
      change set_attribute(:listed, true)
    end
  end

  code_interface do
    define :for_account, args: [:linked_account_id]
    define :track
    define :page, args: [:page_token]
    define :complete, args: [:sync_token]
    define :reset
    define :unlist
    define :relist
  end
end
