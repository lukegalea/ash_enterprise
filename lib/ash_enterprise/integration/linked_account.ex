defmodule AshEnterprise.Integration.LinkedAccount do
  @moduledoc """
  One of an actor's own provider accounts, mapped to the Nango connection that
  holds its credentials (ADR 0011, dogfood deviation 1: the unit of credential
  ownership is the *user account*, so a person with a work and a personal Gmail
  has two rows).

  This is the only place a Nango connection id lives. It is resolved from here
  inside every generated provider action (`:for_operation`) and is never an
  action argument anywhere — including on the provider actions, which accept a
  `linked_account_id` routing hint that must name a row the actor owns.

  `AshEnterprise.Canonical.Account` deliberately does not hold this: it records
  the *outcome* of a connection (which upstream identity a stream belongs to),
  is organization-owned, and is projection-derived. `account_id` links the two
  once the account has been observed.

  ## Choices

    * **User-owned**, owner forced to the acting human (`OwnedByActor`), so
      Basic depth means "my own linked accounts" and nobody links a connection
      for someone else to spend.
    * **`connection_id` is readable only by its owner's own reads.** It is a handle,
      not the secret, but it is the handle the secret key spends: whoever
      reads it can link it as their own and spend it. `sensitive?` keeps it out
      of the audit `data` and inspect output, and a field policy hides it
      (`%Ash.ForbiddenField{}`) from every read except `:for_operation` and
      `:mine`, which only ever return the actor's own rows. A role's read grant on
      linked accounts (an Administrator's `:global` one included) shows that
      the row exists, never the connection.
    * **A connection is linked once, deployment-wide.** A Nango connection is
      global to its Nango environment, so `unique_connection` spans tenants: the
      same connection id cannot be linked again in another tenant.
    * **`label` is `sensitive?`.** It is free text an operator types, and a
      person's name for their account ("work", or their own address) can be
      personal data; ash_events records it as `nil`, so it never reaches the
      immutable audit log. The row still holds it, and an unlink deletes it.
    * **Lifecycle kept** (`deactivate`/`activate`): a deactivated link is never
      resolved, which is how a sync is paused without forgetting the mapping.
    * **`archival?: false`**: unlinking is a hard `:unlink`. A soft-deleted row
      would keep the `(provider_config_key, connection_id)` identity occupied and
      block relinking the same connection.

  ## Erasure (ADR 0024)

  Each linked account is one erasure scope, `connection:<this row's id>`
  (`AshEnterprise.Integration.Landing.scope/1`): everything synced through it
  is sealed under that scope's key. Deactivating stops the syncs; shredding the
  scope destroys the content; unlinking forgets the mapping. In that order.

  ## Zone tags (ADR 0042)

  `data_class` and `residency` are the tags every record landed through the
  account carries, by derivation: zone admission
  (`AshEnterprise.Canonical.Projections.ZoneAdmission`) reads them from here
  for each landed record. Set with `:tag_for_zone` (or at `:link`); both start
  nil, and an untagged account's records are refused. They are an operator's
  statement about the account, not a classification of its content.

  ## Residual

  `:link` trusts that the connection id the actor supplies is theirs. Nango
  knows which end user created a connection; verifying that against the actor
  (a Nango `GET /connection/{id}` call through the proxy façade) belongs in the
  connect-callback flow, which v1 does not have — links are made by the
  operator after the OAuth click-through.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    ownership: :user_owned,
    tenant?: true,
    archival?: false

  postgres do
    table "integration_linked_accounts"
    repo AshEnterprise.Repo

    references do
      reference :account, on_delete: :nilify
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider_config_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 128

      description "The Nango integration key the connection belongs to: google-mail, google-calendar, slack."
    end

    attribute :connection_id, :string do
      allow_nil? false
      public? false
      sensitive? true
      constraints max_length: 256

      description "The Nango connection id. Resolved inside provider actions; never an action argument."
    end

    attribute :label, :string do
      public? true
      sensitive? true
      constraints max_length: 128
      description "The operator's name for the account: work, personal. Never audited."
    end

    # The zone tags (ADR 0042). Everything landed through this account carries
    # them: a landed record is admitted into a zone on its account's tags,
    # never on a guess from its content. Nil is *untagged*, which the
    # admission rule refuses — so an account nobody has tagged projects nothing.
    attribute :data_class, AshEnterprise.Zones.Types.DataClass do
      public? true

      description "How sensitive everything synced through this account is (ADR 0042). Nil: untagged, refused."
    end

    attribute :residency, :string do
      public? true
      constraints match: AshEnterprise.Zones.Residency.pattern()

      description ~S|Where its data may be: "unrestricted" or an ISO 3166 code ("CA"). Nil: untagged, refused.|
    end

    attribute :sync_blocked_reason, :string do
      public? true
      constraints max_length: 64

      description "Why the scheduler stopped syncing this account (a structural reason), or nil."
    end

    attribute :sync_blocked_at, :utc_datetime_usec do
      public? true

      description "When a sync step cancelled for a reason only a person can fix. Nil: syncing."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :account, AshEnterprise.Canonical.Account do
      public? true
      allow_nil? true
      description "The canonical identity this connection reaches, once observed."
    end

    # The verticals' sync cursors, read for sync health only (the Accounts &
    # syncs surface): when each last synced and how much it reaches. Their
    # tokens stay on the cursor rows; nothing here selects them.
    has_many :calendar_cursors, AshEnterprise.Integration.Calendar.SyncCursor do
      description "Google Calendar: one cursor per synced calendar."
    end

    has_one :gmail_sync_state, AshEnterprise.Integration.Gmail.SyncState do
      description "Gmail: the mailbox's one cursor row."
    end

    has_many :slack_cursors, AshEnterprise.Integration.Slack.ConversationCursor do
      description "Slack: one cursor per synced conversation."
    end

    has_one :projection_cursor, AshEnterprise.Integration.ProjectionCursor do
      description "Gmail and Slack: how far landed records have been projected."
    end
  end

  aggregates do
    max :calendar_synced_at, :calendar_cursors, :last_synced_at
    count :calendar_count, :calendar_cursors
    first :gmail_synced_at, :gmail_sync_state, :last_synced_at
    first :gmail_phase, :gmail_sync_state, :phase
    max :slack_synced_at, :slack_cursors, :synced_at
    count :slack_conversation_count, :slack_cursors
    first :projected_at, :projection_cursor, :projected_at
  end

  calculations do
    calculate :provider,
              :string,
              {AshEnterprise.Integration.Calculations.AccountHealth, field: :provider} do
      public? true
      description "The provider's display name."
    end

    calculate :health,
              :string,
              {AshEnterprise.Integration.Calculations.AccountHealth, field: :health} do
      public? true
      description "Syncing, Blocked · <reason>, Paused, or Not synced yet."
    end

    calculate :last_sync,
              :string,
              {AshEnterprise.Integration.Calculations.AccountHealth, field: :last_sync} do
      public? true
      description "The newest cursor sync, on the operator's wall clock, and how long ago."
    end

    calculate :reach,
              :string,
              {AshEnterprise.Integration.Calculations.AccountHealth, field: :reach} do
      public? true
      description "What the sync covers so far: calendars, conversations, or the mailbox phase."
    end

    calculate :projection,
              :string,
              {AshEnterprise.Integration.Calculations.AccountHealth, field: :projection} do
      public? true

      description "Gmail and Slack: when landed records were last projected into the canonical model."
    end

    calculate :blocked, :boolean, expr(not is_nil(sync_blocked_at)) do
      public? true

      description "True while a sync block waits for a person (see `AshEnterprise.Integration.SyncBlock`)."
    end
  end

  identities do
    # Across tenants: a Nango connection belongs to one Nango environment, not
    # to a tenant, so it is linked at most once in the whole deployment.
    identity :unique_connection, [:provider_config_key, :connection_id] do
      all_tenants? true
    end
  end

  # The connection id is the one field a read grant must not hand over (see
  # "Choices"). Every other field is as visible as the row.
  field_policies do
    private_fields :include

    # `:for_operation` resolves the actor's own active accounts for the edge;
    # `:mine` lists the actor's own accounts (the console masks it).
    field_policy :connection_id do
      authorize_if action([:for_operation, :mine])
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    create :link do
      description """
      Record that one of the actor's provider accounts is reachable through a
      Nango connection. The owner is the acting human; it is not an input.
      """

      accept [:provider_config_key, :connection_id, :label, :account_id, :data_class, :residency]
      change AshEnterprise.Integration.Changes.OwnedByActor
    end

    update :tag_for_zone do
      description """
      Declare the zone tags (ADR 0042) of everything synced through this
      account: its data class and its residency restriction. The operator's
      statement about the account, recorded and audited like any other update;
      never inferred from content. Projections admit a landed record into the
      canonical store's zone on these tags
      (`AshEnterprise.Canonical.Projections.ZoneAdmission`); clearing either
      (nil) refuses the account's records from the next replay on.
      """

      accept [:data_class, :residency]
    end

    update :relabel do
      accept [:label, :account_id]
    end

    update :block_sync do
      description """
      A sync step cancelled for a reason retrying cannot fix (revoked token,
      deleted Nango connection, shredded scope, inactive owner): stop the
      scheduler enqueuing this account until a person unblocks it. Called by
      the sync workers; the reason is a structural atom, never a message.
      """

      accept []
      argument :reason, :string, allow_nil?: false, constraints: [max_length: 64]

      change set_attribute(:sync_blocked_reason, arg(:reason))
      change set_attribute(:sync_blocked_at, &DateTime.utc_now/0)
    end

    update :unblock_sync do
      description "Let the scheduler enqueue this account again (after a re-link or a fix)."

      accept []
      change set_attribute(:sync_blocked_reason, nil)
      change set_attribute(:sync_blocked_at, nil)
    end

    destroy :unlink do
      description """
      Forget the mapping and the vertical's sync cursors. The Nango connection
      itself is not touched, and nothing landed through the account is erased:
      shred its erasure scope (`connection:<this id>`) for that, before
      unlinking (docs/runbooks/crypto-shredding.md, "Forgetting a linked
      account").
      """
    end

    action :sync_now, :string do
      description """
      Sync now: enqueue one step of this account's vertical through that
      vertical's own `request_sync`, as the actor (so it is gated as that
      action is). Unique per account — a second click while one is queued is a
      no-op. Returns a status line.
      """

      argument :record_id, :uuid do
        allow_nil? false
        description "The linked account to sync (one the actor can read)."
      end

      run AshEnterprise.Integration.Actions.RequestAccountSync
    end

    read :mine do
      description "The actor's own linked accounts, optionally for one integration."

      argument :provider_config_key, :string, allow_nil?: true

      filter expr(
               owner_id == ^actor(:id) and owner_type == :user and
                 (is_nil(^arg(:provider_config_key)) or
                    provider_config_key == ^arg(:provider_config_key))
             )
    end

    read :owned_by do
      description """
      One user's linked accounts for one integration, whatever their lifecycle.
      The Gmail projection uses it to decide which landed records are the
      replay owner's own: a record is projected for an owner only when it came
      through one of these rows in the replay tenant. Unlinked accounts are
      gone, so their records are no one's to project.
      """

      argument :owner_id, :uuid, allow_nil?: false
      argument :provider_config_key, :string, allow_nil?: false

      filter expr(
               owner_id == ^arg(:owner_id) and owner_type == :user and
                 provider_config_key == ^arg(:provider_config_key)
             )
    end

    read :active_for_integration do
      description """
      Every *active*, unblocked linked account for one integration, across
      tenants, for the sync scheduler (`AshEnterprise.Integration.SyncScheduler`,
      a system actor). A human calling it is still filtered by their own
      grants. The scheduler enqueues ids; each step then re-resolves its
      account as the owning human. An account whose last step cancelled for a
      reason only a person can fix (`:block_sync`) is skipped until it is
      unblocked, so it is not polled every tick.
      """

      argument :provider_config_key, :string, allow_nil?: false

      filter expr(
               lifecycle_status == :active and is_nil(sync_blocked_at) and
                 provider_config_key == ^arg(:provider_config_key)
             )
    end

    read :for_operation do
      description """
      Connection resolution for a provider action: the actor's own *active*
      linked accounts for one integration, narrowed to one row when the action
      was given a `linked_account_id`. Owner comes from the actor, never from
      input.
      """

      argument :provider_config_key, :string, allow_nil?: false
      argument :linked_account_id, :uuid, allow_nil?: true

      filter expr(
               owner_id == ^actor(:id) and owner_type == :user and
                 lifecycle_status == :active and
                 provider_config_key == ^arg(:provider_config_key) and
                 (is_nil(^arg(:linked_account_id)) or id == ^arg(:linked_account_id))
             )
    end
  end

  code_interface do
    define :link
    define :relabel
    define :tag_for_zone
    define :block_sync, args: [:reason]
    define :unblock_sync
    define :unlink
    define :mine, args: [{:optional, :provider_config_key}]
    define :for_operation, args: [:provider_config_key, {:optional, :linked_account_id}]
    define :owned_by, args: [:owner_id, :provider_config_key]
    define :active_for_integration, args: [:provider_config_key]
    define :sync_now, args: [:record_id]
  end
end
