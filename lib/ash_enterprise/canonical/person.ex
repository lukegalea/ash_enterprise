defmodule AshEnterprise.Canonical.Person do
  @moduledoc """
  A person in the operator's world: the organizer of a meeting,
  a message correspondent, a task's assignee.

  The projectors key a person on the email address and nothing else. A person
  the fixture only knows by display name and no address is not linked at all,
  and a duplicate email converges on one row by upsert. One human with two
  addresses (a work address in Slack, another in Gmail) is two rows here;
  resolving them is MDM's job, not the projectors' (PROD-9,
  `AshEnterprise.Mdm.People`): the people sweep proposes the pair, a steward
  confirms, and the merge (`:mdm_merge_into`) folds one row into the other,
  moving its meetings, messages and conversations with it. The projectors then
  link the merged row's address to its golden record
  (`AshEnterprise.Canonical.Projections.Golden`).

  PERSONAL DATA (ADR 0042): the Gmail and Slack projectors write
  correspondents only from records their zone gate admits
  (`AshEnterprise.Canonical.Projections.ZoneGate`). **Owner-only**: no role
  can be granted more than `:basic` on it
  (`AshEnterprise.Security.Privilege.owner_only?/1`), so a person row is
  readable by the user whose sources produced it and nobody else.

  ## Erasure (ADR 0024)

  Each person has an erasure scope of their own (`kind: :data_subject`, ref
  `canonical_person:<id>`; `AshEnterprise.Canonical.PersonSeal`). Their
  address is stored only sealed under it (`encrypted_email`, read as the
  `email` calculation) and found by a blind index (`email_bidx`,
  `AshEnterprise.Erasure.BlindIndex`), which is also the upsert identity.
  Shredding the person's scope makes the address unreadable in this table and
  in the audit copy. A connection shred does not reach a person: a person is
  shared across the sources that saw them, so they are not under any one
  connection's scope.

  `name` stays plaintext and `sensitive?` (kept out of the audit log), so the
  MDM name blocking and name search still run in the database; erasing the
  person (`AshEnterprise.Erasure.PersonErasure`) shreds their scope and blanks
  it on the row (`erase`). `merge_provenance` is `sensitive?` too, and holds
  the prior address only sealed.

  The plaintext `email` column from before the seal is still in the table,
  read as `legacy_email` and blanked as each row is sealed
  (`mix ash_enterprise.erasure.seal_people`); a later migration drops it.
  Listed in `docs/runbooks/crypto-shredding.md`.

  Opt-outs from the platform base, same reasoning as `SourceObject`'s: these
  rows are machine-derived projections — reconstructable from raw landings by
  `Projection.replay/2` — so `archival?: false` (a stale projection is
  re-replayed, not soft-deleted; an archived ghost would also poison the
  replay's upsert identity) and `lifecycle?: false` (a person's lifecycle is
  the source system's business, not the Dataverse Active/Inactive pair).
  Audit stays on: who/what last projected a person is provenance the
  operator's own model should answer for.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    # Only the erase-person act calls it, inside its own authorized transaction.
    machinery_only: [:erase]

  postgres do
    table "canonical_people"
    repo AshEnterprise.Repo

    custom_indexes do
      # MDM-3 blocking (ADR 0017): the trigram shortlist reads
      # `lower(name) % lower($name)` — this GIN index is what keeps that
      # a shortlist instead of an org-wide scan.
      index [:organization_id, "lower(name) gin_trgm_ops"],
        using: "gin",
        name: "canonical_people_name_trgm_idx"
    end

    references do
      # `master` is a display relationship over the merge's own `master_id`:
      # no foreign key, the schema is unchanged.
      reference :master, ignore?: true
      reference :erasure_scope, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    # `sensitive?` (ADR 0024): ash_events records a sensitive input as nil,
    # so the immutable audit log never holds a correspondent's name. The row
    # holds it in plaintext; erasing the person (`:erase`) blanks it there.
    attribute :name, :string do
      public? true
      sensitive? true
      constraints max_length: 256
      description "Display name, when the source system carried one. Stays nil otherwise."
    end

    # CDM master/merged shape (ADR 0017, adopted by ADR 0054): the merge
    # keeps the loser's row, pointing at its survivor.
    attribute :merged, :boolean do
      public? false
      default false
    end

    attribute :master_id, :uuid do
      public? false
    end

    # What the merge took from this record, so the unmerge correction can
    # restore exactly that (prior email, moved identity ids), and who won
    # each field under which rule set (AshEnterprise.Mdm.Changes.MergeInto).
    # Sensitive: a merge writes it with `force_change_attribute`, and the
    # audit log records every forced attribute. The prior address inside it
    # is sealed (`PersonSeal.seal_provenance/2`).
    attribute :merge_provenance, :map do
      public? false
      sensitive? true
    end

    # The address, sealed under the person's own scope (`PersonSeal`). The
    # stored form is ash_cloak's, so the audit copy is ciphertext a shred
    # reaches. Read it as the `email` calculation.
    attribute :encrypted_email, :string do
      public? false
      description "The address, sealed under this person's erasure scope."
    end

    # The v1 linkage key, blind: HMAC of the tenant and the normalized
    # address. Sensitive so the audit log never holds it: the key is not the
    # scope's, so a shred would not reach a copy there.
    attribute :email_bidx, :binary do
      public? false
      sensitive? true
    end

    # The plaintext column from before the seal, kept by the expand migration
    # until every row is sealed and blanked; the contract migration drops it.
    # No action accepts it.
    attribute :legacy_email, :ci_string do
      source :email
      public? false
      sensitive? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      public? false
      attribute_writable? false

      description "This person's own erasure scope: its key seals their address."
    end

    # The merge lineage, readable (MDM-6): a merged loser points at the
    # golden that absorbed it. Public so the golden surface can link it; the
    # link is loaded under the reader's policies like any relationship, so an
    # owner-only survivor the reader cannot see is simply not linked.
    belongs_to :master, __MODULE__ do
      source_attribute :master_id
      define_attribute? false
      public? true
      description "The golden record that absorbed this one, when a merge did."
    end

    has_many :organized_events, AshEnterprise.Canonical.CalendarEvent do
      public? true
      destination_attribute :organizer_id
      description "The calendar events this person organizes."
      temporal_keys {nil, :valid_at}
    end

    has_many :sent_messages, AshEnterprise.Canonical.Message do
      public? true
      destination_attribute :sender_id
      description "The messages this person sent."
    end

    has_many :attendances, AshEnterprise.Canonical.EventAttendee do
      public? true
      description "Their attendance at events, with their responses (a derived join)."
    end

    many_to_many :attended_events, AshEnterprise.Canonical.CalendarEvent do
      public? true
      through AshEnterprise.Canonical.EventAttendee
      join_relationship :attendances
      source_attribute_on_join_resource :person_id
      destination_attribute_on_join_resource :event_id
      description "The events they are invited to."
    end

    has_many :participations, AshEnterprise.Canonical.ConversationParticipant do
      public? true
      description "Their part in conversations (a derived join)."
    end

    many_to_many :conversations, AshEnterprise.Canonical.Conversation do
      public? true
      through AshEnterprise.Canonical.ConversationParticipant
      join_relationship :participations
      source_attribute_on_join_resource :person_id
      destination_attribute_on_join_resource :conversation_id
      description "The threads and Slack conversations they take part in."
    end
  end

  aggregates do
    count :organized_event_count, :organized_events do
      public? true
      description "How many calendar events this person organizes."
    end

    count :sent_message_count, :sent_messages do
      public? true
      description "How many messages they sent."
    end

    count :conversation_count, :participations do
      public? true
      description "How many conversations they take part in."
    end
  end

  calculations do
    calculate :email,
              :ci_string,
              {AshEnterprise.Erasure.Calculations.Unseal,
               field: :encrypted_email, type: :ci_string} do
      public? true
      sensitive? true
      description "The v1 linkage key, unsealed. Nil for a name-only contact."
    end

    calculate :label, :string, AshEnterprise.Canonical.Calculations.PersonLabel do
      public? true
      description "Their display name, else their address."
    end

    # Loaded through `master` under the reader's policies, not joined: a
    # survivor the reader may not read leaves this nil.
    calculate :absorbed_by,
              :string,
              {AshEnterprise.Canonical.Calculations.PersonLabel, relationship: :master} do
      public? true

      description "The golden record that absorbed this one by a merge, by name — as the reader may read it."
    end

    calculate :next_event, :string, AshEnterprise.Canonical.Calculations.NextEvent do
      public? true
      description "The next not-cancelled event they organize, on the operator's wall clock."
    end
  end

  identities do
    # "Unique on the address where present", through its blind index:
    # Postgres unique indexes leave multiple NULLs alone, so name-only
    # contacts do not collide. Per tenant (the tenant attribute is part of
    # every identity here).
    identity :unique_email_bidx, [:email_bidx]
  end

  preparations do
    # Every read unseals the address, a page at a time.
    prepare build(load: [:email])
  end

  changes do
    # Every write: an `email` argument becomes the blind index and the
    # sealed address (`PersonSeal.put_email/3`).
    change AshEnterprise.Canonical.Changes.SealPerson, on: [:create, :update]
  end

  actions do
    defaults [:read]

    read :by_external do
      description """
      Look up the person a source-system contact projected to, by the external
      identity stamped at projection time.

      KNOWN GAP (not yet fixed):
      SourceObject identity is `[external_system, external_id]` *without* the
      stream, and this lookup inherits that shape — two streams sharing an
      external id would land on one row here. Projectors disambiguate by
      filtering `source_metadata["stream"]` when they select their raw rows;
      until the identity is fixed, lookups cannot.
      """

      get? true
      argument :system, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false

      filter expr(external_system == ^arg(:system) and external_id == ^arg(:id))
    end

    read :by_address do
      description """
      The person an exact address belongs to, through its blind index. The
      address is sealed, so only a whole address matches (case aside).
      """

      get? true
      argument :email, :ci_string, allow_nil?: false, sensitive?: true
      prepare AshEnterprise.Canonical.Preparations.ByAddress
    end

    read :goldens do
      description """
      The golden records (MDM-6): persons some SourceIdentity points at and no
      merge has absorbed. The A2UI golden surface reads through this, so a
      merged loser never presents itself as the customer; so does the egress
      run (`AshEnterprise.Mdm.Export`), authorized by the separate
      `AshEnterprise.Mdm.Egress` grant rather than by a grant on Person.
      """

      filter expr(
               merged == false and
                 exists(AshEnterprise.Mdm.SourceIdentity, golden_id == parent(id))
             )
    end

    create :upsert_from_source do
      description """
      The replay write path: upsert on the email identity so every pass of
      `Projection.replay/2` converges on the same row instead of minting
      duplicates. Fields absent from a pass's payload are simply not in
      `upsert_fields` for that write — a name-less source never blanks an
      existing name. The owner context is INSERT-time only: a re-projected
      person keeps whoever projected them first, matching every other
      resource in this domain.
      """

      accept [
        :name,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      argument :email, :ci_string do
        sensitive? true
        constraints max_length: 320

        description "The address: sealed under the person's scope, and its blind index is the upsert identity. Nil for a name-only contact."
      end

      argument :statement_source, :string do
        description "The projector's source name, for the attribute statements this write makes."
      end

      argument :statement_observed_at, :utc_datetime_usec do
        description "The source object's own modified time. Never the read time: a replay must be the same statement."
      end

      change AshEnterprise.Mdm.Changes.AssertFromSource

      upsert? true
      upsert_identity :unique_email_bidx

      # `upsert_fields` is chosen per write by the projector: a payload that
      # carries a display name refreshes it, a name-less payload conflicts and
      # changes nothing. The action cannot pin that choice — it depends on the
      # payload, and pinning it here would let a name-less source blank an
      # existing name.
    end

    update :mdm_survivor_update do
      description "Writes a person's folded values (`AshEnterprise.Mdm.Refold`), and nothing else does."
      accept [:name]
      require_atomic? false

      argument :email, :ci_string do
        sensitive? true
        constraints max_length: 320
        description "The folded address, sealed under the person's scope. Nil releases it."
      end
    end

    update :mdm_merge_into do
      description """
      The merge write (ADR 0054): this record folds into the survivor.
      Non-destructive by construction — the loser keeps its row.
      """

      argument :survivor_id, :uuid, allow_nil?: false
      require_atomic? false

      change AshEnterprise.Mdm.Changes.MergeInto
    end

    update :mdm_repoint_master do
      description """
      A record absorbed earlier follows its golden when that golden is itself
      merged (and back on the unmerge), so `master_id` always names a golden.
      """

      accept [:master_id]
    end

    update :mdm_merge_provenance do
      description "Records what the merge took from this record (ADR 0054: unmerge restores exactly that)."
      accept [:merge_provenance]
    end

    update :mdm_unmerge do
      description "The merge correction: this record stands alone again — email and XREF restored."
      accept []
      validate attribute_equals(:merged, true)
      require_atomic? false

      change set_attribute(:merged, false)
      change set_attribute(:master_id, nil)
      # Stale provenance must not survive the correction: a later
      # merge→unmerge cycle would restore from data the merge retracted.
      change set_attribute(:merge_provenance, nil)
      change AshEnterprise.Mdm.Changes.Unmerge
    end

    create :mdm_replay_golden do
      description """
      The replay write (MDM-5): recreates a deleted golden with its PINNED
      id, so the identity history keeps pointing at the same row and the
      replay is byte-identical, ids included. Only the replay path uses it.
      """

      argument :golden_id, :uuid, allow_nil?: false
      argument :email, :ci_string, sensitive?: true, constraints: [max_length: 320]
      accept [:name, :owner_id, :owning_business_unit_id]

      change set_attribute(:id, arg(:golden_id))
    end

    create :mdm_create_golden do
      description """
      The new-golden write (MDM-4/5 band routing): an omit-banded or
      candidate-less staged row becomes a golden of its own. Deliberately
      NOT an upsert — the omit band ruled a merge out, so an e-mail
      collision with an existing person fails loudly and the caller routes
      the row back to stewardship instead of overwriting anyone.
      """

      argument :email, :ci_string, sensitive?: true, constraints: [max_length: 320]
      accept [:name, :owner_id, :owning_business_unit_id]
    end

    update :erase do
      description """
      Blanks what a shred does not reach on an erased person: the name, the blind
      index, the plaintext column from before the seal and the merge provenance. The
      sealed address stays as ciphertext no key opens, and reads as shredded. Only
      `AshEnterprise.Erasure.PersonErasure`'s `erase` calls it, after authorizing the
      person who asked.
      """

      accept []
      change set_attribute(:name, nil)
      change set_attribute(:email_bidx, nil)
      change set_attribute(:legacy_email, nil)
      change set_attribute(:merge_provenance, nil)
    end

    update :seal_legacy do
      description """
      Seals a row from before addresses were sealed: the plaintext column's
      value under the person's own scope, its blind index, the plaintext
      blanked; a merge's prior address sealed too (`Changes.SealLegacy`).
      Only `mix ash_enterprise.erasure.seal_people` and the projectors'
      upsert call it.
      """

      accept []
      require_atomic? false
      change AshEnterprise.Canonical.Changes.SealLegacy
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :by_address, args: [:email], not_found_error?: false
    define :upsert_from_source
    define :read
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    transform(:name, :hash)
    transform(:legacy_email, :random_email, engine: "hash", domains: ["example.com"])
    # The blind index is a keyed digest of the address: anyone with production's
    # index key could match it to a guess, so a copy has none.
    transform(:email_bidx, :set_null)
    transform(:merge_provenance, :set_null)

    keep(:encrypted_email,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )
  end
end
