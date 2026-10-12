defmodule AshEnterprise.Integration.Gmail.SyncState do
  @moduledoc """
  The Gmail sync cursor for one linked account (epic E4). One row per
  `AshEnterprise.Integration.LinkedAccount`; it holds ids and counters only —
  never a subject, an address, a snippet or a body.

  ## Phases

    * `:bootstrap` — no cursor. The next step reads `users.getProfile` for the
      mailbox's current `historyId`, records it as `backfill_history_id` (and
      when, as `backfill_started_at`), and moves to `:backfill`.
    * `:backfill` — a **bounded** recent-messages pass (`users.messages.list`
      over a configurable window and message cap), one page at a time, with
      `backfill_page_token` as the resume point. When it finishes, the
      `historyId` captured *before* the backfill becomes the incremental
      cursor, so nothing that arrived during the backfill is missed.
    * `:incremental` — `users.history.list` from `history_id`, committed after
      every page (to the last history record processed, then to the response
      `historyId` on the final page).

  ## Sync reset

  Wrong-cursor conditions are an explicit action, never a silent rewind:
  `reset_sync` (reason `:history_expired` when Gmail answers 404 for a
  `startHistoryId` it no longer retains, `:backfill_stale` when an unfinished
  backfill is resumed after longer than its window, `:operator` when a person
  asks) puts the row back to `:bootstrap`, so the next step runs a bounded
  resync.

  ## Choices

    * **User-owned**, owner forced to the acting human: Basic depth reads "my
      own sync state", the same reach the actor has over the linked account.
    * **`lifecycle?: false`**: pausing a sync is the linked account's
      lifecycle (`deactivate`), not this row's.
    * **`archival?: false`**: a soft-deleted row would keep the
      `linked_account_id` identity occupied.
    * Audit stays on: who reset a cursor, and when, is provenance worth having,
      and the row carries nothing but ids and counters.

  ## Entry point

      SyncState.request_sync(%{linked_account_id: id}, actor: actor, tenant: tenant)

  upserts the row (creating it in `:bootstrap`) and enqueues one
  `AshEnterprise.Integration.Gmail.SyncWorker` step, in the same transaction.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration.Gmail.SyncDomain,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "integration_gmail_sync_states"
    repo AshEnterprise.Repo

    references do
      # The cursor means nothing without the account it reads; unlinking the
      # account forgets it.
      reference :linked_account, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :phase, :atom do
      allow_nil? false
      public? true
      default :bootstrap
      constraints one_of: [:bootstrap, :backfill, :incremental]
      description "Where the sync is: bootstrap (no cursor), backfill (bounded), incremental."
    end

    attribute :history_id, :string do
      public? true
      constraints max_length: 64
      description "The committed users.history.list cursor. Nil until the backfill completes."
    end

    attribute :backfill_history_id, :string do
      public? true
      constraints max_length: 64

      description "The mailbox historyId captured before the backfill; becomes history_id when it ends."
    end

    attribute :backfill_started_at, :utc_datetime_usec do
      public? true

      description "When backfill_history_id was captured. A backfill resumed after more than the backfill window is restarted."
    end

    attribute :backfill_page_token, :string do
      public? true
      constraints max_length: 512
      description "Resume point of an unfinished backfill."
    end

    attribute :backfill_landed, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0

      description "Message ids the current backfill has consumed (landed or skipped), against the configured cap."
    end

    attribute :last_synced_at, :utc_datetime_usec do
      public? true
      description "When a sync step last completed."
    end

    attribute :sync_requested_at, :utc_datetime_usec do
      public? true
      description "When a sync was last requested through request_sync."
    end

    attribute :reset_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
      description "How many times the cursor has been reset."
    end

    attribute :last_reset_at, :utc_datetime_usec do
      public? true
      description "When the cursor was last reset."
    end

    attribute :last_reset_reason, :atom do
      public? true
      constraints one_of: [:history_expired, :backfill_stale, :operator]
      description "Why the cursor was last reset."
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
      description "The Gmail linked account this cursor reads."
    end
  end

  identities do
    identity :unique_linked_account, [:linked_account_id]
  end

  actions do
    defaults [:read]

    create :open do
      description """
      Ensure the cursor row for one of the actor's own Gmail linked accounts
      exists (in :bootstrap on first use). Idempotent; enqueues nothing. The
      sync worker calls this when it is run for an account that was never
      requested through request_sync.
      """

      accept [:linked_account_id]

      upsert? true
      upsert_identity :unique_linked_account
      upsert_fields [:linked_account_id]

      change AshEnterprise.Integration.Changes.OwnedByActor
      change AshEnterprise.Integration.Gmail.Changes.RequireOwnGmailAccount
    end

    create :request_sync do
      description """
      Ask for one sync step of one of the actor's own Gmail linked accounts.
      Creates the cursor row on first use (in :bootstrap), touches
      `sync_requested_at` otherwise, and enqueues the sync worker in the same
      transaction. The owner is the acting human; it is not an input.
      """

      accept [:linked_account_id]

      upsert? true
      upsert_identity :unique_linked_account
      upsert_fields [:sync_requested_at]

      change set_attribute(:sync_requested_at, &DateTime.utc_now/0)
      change AshEnterprise.Integration.Changes.OwnedByActor
      change AshEnterprise.Integration.Gmail.Changes.RequireOwnGmailAccount
      change AshEnterprise.Integration.Gmail.Changes.EnqueueSync
    end

    update :advance do
      description """
      Persist sync progress: phase, the committed cursor and the backfill's
      resume point. Called by `AshEnterprise.Integration.Gmail.Sync` as the
      account's owner, after the records a cursor covers have landed.
      """

      accept [
        :phase,
        :history_id,
        :backfill_history_id,
        :backfill_started_at,
        :backfill_page_token,
        :backfill_landed,
        :last_synced_at
      ]
    end

    update :reset_sync do
      description """
      Sync-reset: forget the cursor so the next step runs a bounded resync
      (bootstrap + backfill). Gmail's 404 for an expired startHistoryId calls
      this with reason :history_expired; a backfill resumed after longer than
      its window (its captured historyId would replay everything since) with
      :backfill_stale; an operator may call it with :operator. Never a silent
      rewind.
      """

      accept []

      # CountReset reads the loaded row's count: the audit wrapper refuses
      # atomic changes, so this update cannot be atomic either way.
      require_atomic? false

      argument :reason, :atom do
        allow_nil? false
        default :operator
        constraints one_of: [:history_expired, :backfill_stale, :operator]
      end

      change set_attribute(:phase, :bootstrap)
      change set_attribute(:history_id, nil)
      change set_attribute(:backfill_history_id, nil)
      change set_attribute(:backfill_started_at, nil)
      change set_attribute(:backfill_page_token, nil)
      change set_attribute(:backfill_landed, 0)
      change set_attribute(:last_reset_reason, arg(:reason))
      change set_attribute(:last_reset_at, &DateTime.utc_now/0)
      change AshEnterprise.Integration.Gmail.Changes.CountReset
    end

    read :for_linked_account do
      description "The cursor row for one linked account, if a sync was ever requested."
      get? true
      argument :linked_account_id, :uuid, allow_nil?: false
      filter expr(linked_account_id == ^arg(:linked_account_id))
    end
  end

  code_interface do
    define :open
    define :request_sync
    define :advance
    define :reset_sync
    define :for_linked_account, args: [:linked_account_id], not_found_error?: false
  end
end
