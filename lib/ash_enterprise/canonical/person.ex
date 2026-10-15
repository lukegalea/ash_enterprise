defmodule AshEnterprise.Canonical.Person do
  @moduledoc """
  A person in the operator's world (dogfood §11): the organizer of a meeting,
  a message correspondent, a task's assignee.

  Identity for v1 is the email address and nothing else — matching the program
  decision that entity resolution stays external-id + email, with no fuzzy
  matching (roadmap P4). A person the fixture only knows by display name and no
  address is not linked at all; a duplicate email merges automatically by
  upsert, and nobody pretends that is entity resolution.

  PERSONAL DATA (ADR 0042): the Gmail and Slack projectors write
  correspondents only from records their zone gate admits
  (`AshEnterprise.Canonical.Projections.ZoneGate`). **Owner-only**: no role
  can be granted more than `:basic` on it
  (`AshEnterprise.Security.Privilege.owner_only?/1`), so a person row is
  readable by the user whose sources produced it and nobody else.

  ## Erasure (ADR 0024)

  `name` and `email` are **not** sealed under an erasure scope: `email` is the
  upsert identity, and a sealed value (randomized ciphertext) cannot be one
  without a blind index. They are `sensitive?`, which keeps them out of the
  immutable audit log -- ash_events records sensitive inputs as nil -- so a
  connection shred leaves them only in this table, where rows are ordinary
  mutable data. Shredding a connection does not reach them; removing a
  correspondent is a row-level delete, not a key destroy. Listed in
  `docs/runbooks/crypto-shredding.md`.

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
    archival?: false

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
  end

  attributes do
    uuid_primary_key :id

    # `sensitive?` on name and email (ADR 0024): ash_events records a
    # sensitive input as nil, so the immutable audit log never holds a
    # correspondent's name or address. The row itself still does, in
    # plaintext and outside any erasure scope -- see "Erasure" above.
    attribute :name, :string do
      public? true
      sensitive? true
      constraints max_length: 256
      description "Display name, when the source system carried one. Stays nil otherwise."
    end

    # CDM master/merged shape (ADR 0017, adopted by ADR 0053): the merge
    # keeps the loser's row, pointing at its survivor.
    attribute :merged, :boolean do
      public? false
      default false
    end

    attribute :master_id, :uuid do
      public? false
    end

    # What the merge took from this record, so the unmerge correction can
    # restore exactly that (prior email, moved identity ids).
    attribute :merge_provenance, :map do
      public? false
    end

    attribute :email, :ci_string do
      public? true
      sensitive? true
      constraints max_length: 320
      description "The v1 linkage key. Nullable: a name-only contact is a person with no link."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :organized_events, AshEnterprise.Canonical.CalendarEvent do
      public? true
      destination_attribute :organizer_id
      description "The calendar events this person organizes."
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
    calculate :label, :string, expr(name || type(email, :string)) do
      public? true
      description "Their display name, else their address."
    end

    calculate :next_event, :string, AshEnterprise.Canonical.Calculations.NextEvent do
      public? true
      description "The next not-cancelled event they organize, on the operator's wall clock."
    end
  end

  identities do
    # "Unique on email where present": Postgres unique indexes leave multiple
    # NULLs alone, so name-only contacts do not collide.
    identity :unique_email, [:email]
  end

  actions do
    defaults [:read]

    read :by_external do
      description """
      Look up the person a source-system contact projected to, by the external
      identity stamped at projection time.

      KNOWN GAP (E1 review, fix owned by a dedicated E1 follow-up):
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

    read :goldens do
      description """
      The golden records (MDM-6): persons some SourceIdentity points at and no
      merge has absorbed. The A2UI golden surface reads through this, so a
      merged loser never presents itself as the customer.
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
        :email,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_email

      # `upsert_fields` is chosen per write by the projector: a payload that
      # carries a display name refreshes it, a name-less payload conflicts and
      # changes nothing. The action cannot pin that choice — it depends on the
      # payload, and pinning it here would let a name-less source blank an
      # existing name.
    end

    update :mdm_survivor_update do
      description "The merge's survivor write: fill the survivor's gaps from the loser (ADR 0053 survivorship)."
      accept [:name, :email]
    end

    update :mdm_merge_into do
      description """
      The merge write (ADR 0053): this record folds into the survivor.
      Non-destructive by construction — the loser keeps its row.
      """

      argument :survivor_id, :uuid, allow_nil?: false
      require_atomic? false

      change AshEnterprise.Mdm.Changes.MergeInto
    end

    update :mdm_merge_provenance do
      description "Records what the merge took from this record (ADR 0053: unmerge restores exactly that)."
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
      accept [:name, :email, :owner_id, :owning_business_unit_id]

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

      accept [:name, :email, :owner_id, :owning_business_unit_id]
    end

    action :mdm_export, {:array, :map} do
      description """
      The egress departure (MDM-6, ADR 0053 §8): the tenant's active `:egress`
      mapping turns this tenant's golden records into customer-shaped rows —
      after the zone disclosure gate refuses the departure on the residency
      tags recorded at land. Person-gated and grant-checked like every
      surface; see `AshEnterprise.Mdm.Export`.
      """

      argument :zone, :string, allow_nil?: false

      run AshEnterprise.Mdm.Export
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
    define :mdm_export, args: [:zone]
  end

  policies do
    # The egress departure is a grant-checked act (MDM-6): a principal
    # holding a role grant on the tenant's data may export; a person with
    # no grants — and a nil actor — is refused by the grant union below.
    # The zone disclosure gate itself lives in the run
    # (AshEnterprise.Mdm.Export), on the land-recorded residency tags.
    policy action(:mdm_export) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
