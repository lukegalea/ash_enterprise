defmodule AshEnterprise.Integration.Slack.ConversationCursor do
  @moduledoc """
  Where the Slack sync stands in one conversation, for one linked account.

  `conversations.history` returns messages newest first and pages *backwards*
  with an opaque `cursor`, bounded below by `oldest` (exclusive). One **pass**
  fetches everything newer than the high-water mark:

    * `latest_ts` — the newest `ts` of the last *completed* pass. The next pass
      uses it as `oldest`, so it only sees newer messages.
    * `pass_oldest`, `page_cursor`, `pass_latest_ts` — an in-progress pass: the
      bound it started with, the page to fetch next, and the newest `ts` it has
      seen. Saved after every landed page, so a step that stops part-way (page
      budget, rate limit, crash) resumes the same pass instead of re-fetching
      it. Landing is an upsert, so a page re-fetched after a crash between
      "landed" and "saved" lands nothing new.

  Completing a pass moves `latest_ts` forward and clears the pass fields.

  **Holds no content**: channel ids, Slack `ts` strings and Slack's opaque page
  cursors only.

  ## Resets are explicit

  A page cursor Slack no longer accepts (`invalid_cursor`, edge reason `:gone`)
  is handled by `:reset_pass` — drop the in-progress pass, keep the high-water
  mark — never by silently rewinding. `:rewind` forgets the high-water mark
  too, so the next pass re-backfills; it is the operator's tool, the sync never
  calls it.

  ## Opt-outs

  Bookkeeping for a machine process, in the shape of `SourceObject`'s:
  `ownership: :none` and `tenant?: false` (written only by the sync, after it
  has resolved the linked account under the actor's own policies), no
  lifecycle/archival (a cursor is overwritten, never soft-deleted — a ghost row
  would hold the identity), and `audit?: false` (one write per fetched page;
  it records positions, not decisions, and is reconstructable by `:rewind`).
  Unlinking the account deletes its cursors (`on_delete: :delete`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration.Slack.Domain,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false

  postgres do
    table "integration_slack_conversation_cursors"
    repo AshEnterprise.Repo

    # The default name (table + identity) is past Postgres's 63-byte limit.
    identity_index_names unique_conversation:
                           "integration_slack_cursors_unique_conversation_index"

    references do
      reference :linked_account, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :channel_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
      description "Slack's conversation id (C…, G…, D…)."
    end

    attribute :latest_ts, :string do
      public? true
      constraints max_length: 32
      description "Newest message ts of the last completed pass; the next pass's `oldest`."
    end

    attribute :pass_oldest, :string do
      public? true
      constraints max_length: 32
      description "The `oldest` bound the in-progress pass started with."
    end

    attribute :page_cursor, :string do
      public? true
      constraints max_length: 512
      description "Slack's next_cursor for the in-progress pass; nil when no pass is in progress."
    end

    attribute :pass_latest_ts, :string do
      public? true
      constraints max_length: 32
      description "Newest ts the in-progress pass has seen so far."
    end

    attribute :synced_at, :utc_datetime_usec do
      public? true
      description "When the last pass completed."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :linked_account, AshEnterprise.Integration.LinkedAccount do
      allow_nil? false
      public? true
      attribute_public? true
      domain AshEnterprise.Integration
    end
  end

  identities do
    identity :unique_conversation, [:linked_account_id, :channel_id]
  end

  actions do
    defaults [:read]

    read :for_account do
      description "Every conversation cursor of one linked account."
      argument :linked_account_id, :uuid, allow_nil?: false
      filter expr(linked_account_id == ^arg(:linked_account_id))
      prepare build(sort: [channel_id: :asc])
    end

    create :save do
      description """
      Upsert the full position of one conversation. The sync computes the whole
      state and writes it; there is no partial-field path to get wrong.
      """

      accept [
        :linked_account_id,
        :channel_id,
        :latest_ts,
        :pass_oldest,
        :page_cursor,
        :pass_latest_ts,
        :synced_at
      ]

      upsert? true
      upsert_identity :unique_conversation
      upsert_fields [:latest_ts, :pass_oldest, :page_cursor, :pass_latest_ts, :synced_at]
    end

    update :reset_pass do
      description """
      Sync-reset for a page cursor Slack refused (`invalid_cursor`): drop the
      in-progress pass, keep the high-water mark. The next step starts a fresh
      pass from `latest_ts`.
      """

      accept []
      change set_attribute(:pass_oldest, nil)
      change set_attribute(:page_cursor, nil)
      change set_attribute(:pass_latest_ts, nil)
    end

    update :rewind do
      description """
      Forget everything about this conversation's position: the next step
      re-backfills it from the configured backfill window. Operator-only; the
      sync never calls it.
      """

      accept []
      change set_attribute(:latest_ts, nil)
      change set_attribute(:pass_oldest, nil)
      change set_attribute(:page_cursor, nil)
      change set_attribute(:pass_latest_ts, nil)
      change set_attribute(:synced_at, nil)
    end
  end

  code_interface do
    define :for_account, args: [:linked_account_id]
    define :save
    define :reset_pass
    define :rewind
  end
end
