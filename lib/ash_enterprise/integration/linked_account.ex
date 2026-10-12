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
    * **`connection_id` is `sensitive?` and not `public?`**: it is a handle, not
      the secret, but it is the handle the secret key spends, so it stays out of
      the audit `data`, inspect output and every API surface.
    * **Lifecycle kept** (`deactivate`/`activate`): a deactivated link is never
      resolved, which is how a sync is paused without forgetting the mapping.
    * **`archival?: false`**: unlinking is a hard `:unlink`. A soft-deleted row
      would keep the `(provider_config_key, connection_id)` identity occupied and
      block relinking the same connection.

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
      constraints max_length: 128
      description "The operator's name for the account: work, personal."
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
    identity :unique_connection, [:provider_config_key, :connection_id]
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

    destroy :unlink do
      description "Forget the mapping. The Nango connection itself is not touched."
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
    define :unlink
    define :mine, args: [{:optional, :provider_config_key}]
    define :for_operation, args: [:provider_config_key, {:optional, :linked_account_id}]
  end
end
