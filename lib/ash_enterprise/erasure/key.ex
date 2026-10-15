defmodule AshEnterprise.Erasure.Key do
  @moduledoc """
  One erasure scope's data-encryption key, stored wrapped under the master key
  (`AshEnterprise.Erasure.Crypto`). Destroying this row is the shred.

  ## Deliberate opt-outs

    * `audit?: false` — **the reason this is a separate resource from
      `AshEnterprise.Erasure.Scope`.** AshEvents records every attribute a
      change sets in `changed_attributes`, and the audit log is permanent by
      construction (ADR 0020). A wrapped key written there would outlive every
      shred, and anyone holding the master key could unwrap it from the log.
      The structural facts — a scope opened, a scope shredded — are audited on
      `Scope` instead.
    * `archival?: false` — a soft-deleted key still exists. `destroy_for_shred`
      is a real `DELETE`.
    * `policies?: false`, and the policy below grants nothing to anyone. The
      only path to these rows is `AshEnterprise.Erasure.Keyring`, which reads
      them with `authorize?: false`; not the admin UI, not an API, not an agent.

  ## Identities that make key reuse a constraint violation

    * `unique_scope` on `scope_id` — one key per scope, ever.
    * `unique_fingerprint` on a hash of the key bytes — no two scopes can hold
      the same key, whatever code path tried to give them one.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Erasure,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    policies?: false

  postgres do
    table "erasure_keys"
    repo AshEnterprise.Repo

    references do
      # A scope is never deleted (it is not archivable and has no destroy), so
      # restrict is a tripwire, not a workflow.
      reference :scope, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :wrapped_key, :binary do
      allow_nil? false
      public? false
      sensitive? true

      description "The scope's data key, AES-256-GCM-wrapped under the master key, bound to the scope id."
    end

    attribute :fingerprint, :string do
      allow_nil? false
      public? false
      sensitive? true
      constraints max_length: 64
      description "Domain-separated SHA-256 of the key bytes. Unique: no two scopes share a key."
    end

    attribute :master_key_id, :string do
      allow_nil? false
      public? false
      constraints max_length: 32
      description "Which master key wrapped this key, so a wrong master key is a named error."
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_scope, [:scope_id]
    identity :unique_fingerprint, [:fingerprint]
  end

  actions do
    read :for_scope do
      get? true
      argument :scope_id, :uuid, allow_nil?: false
      filter expr(scope_id == ^arg(:scope_id))
    end

    create :issue do
      accept [:scope_id, :wrapped_key, :fingerprint, :master_key_id]
    end

    destroy :destroy_for_shred do
      primary? true
    end
  end

  policies do
    policy always() do
      description "No actor is ever granted key material; only the Keyring reads it."
      authorize_if never()
    end
  end

  code_interface do
    define :for_scope, args: [:scope_id], not_found_error?: false
    define :issue
    define :destroy_for_shred
  end
end
