defmodule AshEnterprise.Erasure.Scope do
  @moduledoc """
  An erasure scope: the unit that one key encrypts and one shred destroys
  (ADR 0024, erasure half).

  ## The scope model

  A scope is `(kind, ref)`, unique, and owns exactly one key for its whole life:

    * `kind: :connection` — **everything that came in through one external
      connection**: one linked account, one Nango connection, one tap pipeline.
      This is the dogfood case ("forget my VendorPM Slack"), and it is the right
      unit for ingested content because provenance is the one thing every
      landed row knows for certain about itself. `ref` is the connection's own
      stable identifier — the linked-account id once that resource exists, or
      `pipeline:<name>` for a configured tap (`AshEnterprise.Ingestion.TapWorker`).
    * `kind: :data_subject` — ADR 0024's original unit, one person's data. `ref`
      is the subject's stable id. It covers content that belongs to that one
      person; it does *not* reach a message that merely mentions them under a
      connection scope, because a row is sealed under exactly one scope. Content
      with many subjects lives under its source's scope.

  A row names its scope in `erasure_scope_id`, and the scope id is also inside
  every sealed value's authenticated header, so the two cannot drift.

  `ref` and `label` are structural: they are audited when the scope opens and
  outlive its shred. Use opaque identifiers (a Nango connection id, a Slack team
  id), never an email address or a person's name.

  Scopes are not tenant-scoped, matching `AshEnterprise.Ingestion.SourceObject`.
  A global write grant on this resource therefore reaches every scope in the
  deployment — right for the single-operator dogfood deployment, and something
  to change before scopes are shared between tenants.

  ## One key per scope, never shared, never reissued

  `AshEnterprise.Erasure.Key` carries a unique identity on `scope_id` (one key
  per scope) and on the key's fingerprint (no two scopes hold the same key
  bytes), and wraps the key with the scope id as authenticated data (a key moved
  to another scope does not unwrap). ADR 0024 names key reuse across subjects as
  the dangerous bug — a reused key makes one shred erase more than intended, or
  leave a "shredded" scope readable — so it is refused three ways.

  A shredded scope is never reopened. `ensure` returns it as shredded, and
  landing under it is refused. Re-ingesting the same source means opening a new
  scope with a new `ref`.

  ## Why this is audited and the key is not

  This resource is the structural fact: a scope was opened, by whom, and later
  shredded, by whom, why, and when. All of that belongs in the immutable log.
  The key material belongs nowhere near it — anything written to the audit log
  is permanent by construction (ADR 0020), so a wrapped key recorded there would
  survive every shred. Hence two resources: `Scope` (audited) and `Key`
  (`audit?: false`, policies that grant nothing).

  `archival?: false`: a scope is never deleted. Its tombstone is the evidence
  that the shred happened, and canonical rows keep their foreign key to it.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Erasure,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    policies?: false

  postgres do
    table "erasure_scopes"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:connection, :data_subject]
      description "What the scope covers: one external connection, or one data subject."
    end

    attribute :ref, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true, allow_empty?: false

      description "The connection's or subject's stable identifier. Unique per kind; never reused."
    end

    attribute :label, :string do
      public? true
      constraints max_length: 256

      description "Operator-facing name, e.g. \"VendorPM company Slack\". Structural, never content."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :shredded]

      description "Shredded is terminal: the key is destroyed and the scope can never be reopened."
    end

    attribute :shredded_at, :utc_datetime_usec do
      public? true
      description "When the key was destroyed."
    end

    attribute :shred_reason, :string do
      public? true
      constraints max_length: 1024
      description "Why, in the operator's words. Recorded in the audit trail with the shred."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_one :key, AshEnterprise.Erasure.Key do
      destination_attribute :scope_id
      public? false
    end
  end

  identities do
    identity :unique_scope, [:kind, :ref]
  end

  actions do
    defaults [:read]

    read :by_ref do
      description "The scope for one `(kind, ref)`, or nil."
      get? true

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:connection, :data_subject]]

      argument :ref, :string, allow_nil?: false

      filter expr(kind == ^arg(:kind) and ref == ^arg(:ref))
    end

    create :open do
      description "Open a scope and issue its key, in one transaction. Prefer `ensure`."
      accept [:kind, :ref, :label]
      change AshEnterprise.Erasure.Changes.IssueScopeKey
    end

    action :ensure, :struct do
      description """
      The scope for `(kind, ref)`, opened with a fresh key the first time. A
      shredded scope is returned as shredded, never reopened.
      """

      constraints instance_of: __MODULE__

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:connection, :data_subject]]

      argument :ref, :string, allow_nil?: false
      argument :label, :string

      run AshEnterprise.Erasure.Actions.EnsureScope
    end

    update :shred do
      description """
      Destroy the scope's key, irreversibly. Every value sealed under it — raw
      landings, canonical rows, and the ciphertext their audit events carry —
      becomes permanently unreadable and reads back as
      `AshEnterprise.Erasure.Shredded`. Rows, foreign keys and the audit hash
      chain are untouched.

      `confirm` must equal the scope's `ref`; `reason` is recorded in the audit
      trail. Only a human holding a write grant on erasure scopes may shred.
      """

      accept []
      argument :confirm, :string, allow_nil?: false
      argument :reason, :string, allow_nil?: false, constraints: [max_length: 1024]

      # Not atomic: ConfirmShred compares the argument with the record's `ref`
      # and `status`, which needs the record loaded. A single-record operator
      # action; never bulk.
      require_atomic? false

      validate AshEnterprise.Erasure.Validations.ConfirmShred

      change set_attribute(:status, :shredded)
      change set_attribute(:shredded_at, &DateTime.utc_now/0)
      change set_attribute(:shred_reason, arg(:reason))
      change AshEnterprise.Erasure.Changes.DestroyScopeKey
    end
  end

  # Declared in full rather than inherited (`policies?: false`) for one reason:
  # the inherited set opens with a system-actor bypass, and a shred must not be
  # reachable by any system actor. No `forbid_if` anywhere -- each policy is a
  # union of grant paths, and the shred policy simply has fewer of them.
  policies do
    policy action(:shred) do
      description "Only a human holding a write grant on erasure scopes may destroy a key."
      authorize_if AshEnterprise.Erasure.Checks.HumanRoleGrant
    end

    policy action_type([:read, :create, :action]) do
      description "Adapters (system actors) and granted operators may look up and open scopes."
      authorize_if AshEnterprise.Security.Checks.SystemActor
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
