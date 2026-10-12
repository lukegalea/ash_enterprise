defmodule AshEnterprise.Ingestion.SourceObject do
  @moduledoc """
  The immutable raw-landing record for one external object (epic E1, ADR 0010).

  One row per `(external_system, external_id)`. The `raw_payload` is exactly what
  the tap emitted — no interpretation, no normalization. Canonical projections
  (epic E4, ADR 0037) are derived from these rows and must remain replayable from
  them; that replayability is why this table is append/upsert-only and why the
  sync `cursor` lives here rather than in job args.

  Opt-outs from the platform base are deliberate and greppable: `audit?: false`
  (machine-generated, high volume, fully reconstructable from the tap), no
  lifecycle/archival (raw rows are never state-tracked or soft-deleted),
  `tenant?: false` and `ownership: :none` (ingestion is infrastructure, the
  operator's own accounts — canonical, actor-facing rows in E4 carry the
  ownership instead).

  Identity: `unique_source_object` on `[external_system, external_id]`. The
  `land` action upserts on it, which is what makes re-running a pipeline
  idempotent — a repeated tap pass updates payload/cursor in place instead of
  duplicating rows.

  ## Erasure: every landing is sealed under a scope (ADR 0024)

  `raw_payload` is encrypted at rest under the key of the
  `AshEnterprise.Erasure.Scope` named in `erasure_scope_id` — required on
  `land`. An adapter lands "this record under scope X": it resolves its
  connection's scope once (`AshEnterprise.Erasure.ensure_scope/4`) and passes
  the id. Reads decrypt transparently while the scope is live; after the scope
  is shredded, `raw_payload` reads as `AshEnterprise.Erasure.Shredded` and the
  row's structural columns (system, external id, stream, fetch time) remain.
  Landing under a shredded scope is refused.

  The ciphertext is not deterministic, so a re-landed row's
  `encrypted_raw_payload` bytes change even when the payload does not; the
  decrypted payload is what replay determinism is about.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Ingestion,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    extra_extensions: [AshCloak]

  postgres do
    table "ingestion_source_objects"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end
  end

  # The payload is sealed under its erasure scope's key: ash_cloak supplies the
  # `encrypted_raw_payload` column, the sensitive argument and the decrypting
  # calculation; `SealUnderScope` (below) does the encrypting, because only the
  # changeset knows which scope's key to use. See AshEnterprise.Erasure.Vault.
  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:raw_payload]
    decrypt_by_default([:raw_payload])
    encrypt_nil?(false)
  end

  attributes do
    uuid_primary_key :id

    attribute :external_system, :string do
      allow_nil? false
      public? true
      constraints max_length: 64

      description "Which external system the object came from: postgres, gmail, google_calendar, slack."
    end

    attribute :external_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 512
      description "The source system's own id for the object, verbatim."
    end

    attribute :raw_payload, :map do
      allow_nil? false
      public? true

      description "The exact record the tap emitted, uninterpreted. Sealed under the erasure scope."
    end

    attribute :source_metadata, :map do
      public? true
      description "Tap/bookkeeping metadata: stream name, tap name, replication keys."
    end

    attribute :cursor, :map do
      public? true
      description "Singer STATE value in effect for this row; advanced per successful run."
    end

    attribute :fetched_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "When the tap emitted the record."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true

      description "The connection this record came in through; its key seals `raw_payload`."
    end
  end

  changes do
    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:raw_payload]},
      on: [:create, :update]
  end

  identities do
    identity :unique_source_object, [:external_system, :external_id]
  end

  actions do
    defaults [:read]

    read :by_system do
      argument :external_system, :string, allow_nil?: false

      filter expr(external_system == ^arg(:external_system))
    end

    read :by_external do
      description """
      The identity lookup canonical projections link back through: one raw row
      by `(external_system, external_id)`.

      KNOWN GAP (E1 review, fix owned by a dedicated E1 follow-up): this
      identity does not include the stream, so two streams landing the same
      external id collide into one row. Consumers mitigate by also matching
      `source_metadata["stream"]` when they select rows for projection; this
      lookup cannot, and that is the gap the E1 follow-up closes.
      """

      get? true
      argument :external_system, :string, allow_nil?: false
      argument :external_id, :string, allow_nil?: false

      filter expr(external_system == ^arg(:external_system) and external_id == ^arg(:external_id))
    end

    create :land do
      description """
      Idempotent landing of one raw record. Upserts on the source identity so a
      re-run of the same tap pass refreshes payload, cursor and fetch time in
      place rather than duplicating the row.

      `erasure_scope_id` is required: the record is sealed under that scope's
      key, and refused if the scope has been shredded.
      """

      accept [
        :erasure_scope_id,
        :external_system,
        :external_id,
        :raw_payload,
        :source_metadata,
        :cursor,
        :fetched_at
      ]

      upsert? true
      upsert_identity :unique_source_object

      # The scope moves with the payload: a row's ciphertext and its
      # `erasure_scope_id` always name the same scope.
      upsert_fields [
        :erasure_scope_id,
        :encrypted_raw_payload,
        :source_metadata,
        :cursor,
        :fetched_at
      ]
    end

    update :advance_cursor do
      description "Persist the STATE value a completed run ended on. Used by the tap worker."
      accept [:cursor]
    end

    update :reset_cursor do
      description """
      Sync-reset: drop the stored cursor so the next run re-syncs from the
      beginning. Wrong-cursor conditions (Gmail 410 Gone, Calendar invalid sync
      token) are an explicit action, never a silent rewind.
      """

      accept []
      change set_attribute(:cursor, nil)
    end
  end

  code_interface do
    define :land, action: :land

    # The call an adapter makes: "land this record under scope X". The scope is
    # positional so it cannot be forgotten in the attribute map.
    #
    #     SourceObject.land_under!(scope.id, %{external_system: "slack", ...}, opts)
    define :land_under, action: :land, args: [:erasure_scope_id]
    define :advance_cursor, action: :advance_cursor
    define :reset_cursor, action: :reset_cursor
    define :by_system, action: :by_system, args: [:external_system]

    define :by_external,
      action: :by_external,
      args: [:external_system, :external_id],
      not_found_error?: false
  end
end
