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

      accept [:provider_config_key, :connection_id, :label, :account_id]
      change AshEnterprise.Integration.Changes.OwnedByActor
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
    define :block_sync, args: [:reason]
    define :unblock_sync
    define :unlink
    define :mine, args: [{:optional, :provider_config_key}]
    define :for_operation, args: [:provider_config_key, {:optional, :linked_account_id}]
    define :owned_by, args: [:owner_id, :provider_config_key]
    define :active_for_integration, args: [:provider_config_key]
  end
end
