defmodule AshEnterprise.Canonical.Person do
  @moduledoc """
  A person in the operator's world (dogfood §11): the organizer of a meeting,
  a message correspondent, a task's assignee.

  Identity for v1 is the email address and nothing else — matching the program
  decision that entity resolution stays external-id + email, with no fuzzy
  matching (roadmap P4). A person the fixture only knows by display name and no
  address is not linked at all; a duplicate email merges automatically by
  upsert, and nobody pretends that is entity resolution.

  PERSONAL DATA (ADR 0042): when the Gmail/Slack verticals start projecting
  correspondents from real mailboxes, zone admission must already gate the
  SourceObject land path. See the TODO on
  `AshEnterprise.Canonical.Projection` before wiring those projectors.

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
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      public? true
      constraints max_length: 256
      description "Display name, when the source system carried one. Stays nil otherwise."
    end

    attribute :email, :ci_string do
      public? true
      constraints max_length: 320
      description "The v1 linkage key. Nullable: a name-only contact is a person with no link."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
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
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
