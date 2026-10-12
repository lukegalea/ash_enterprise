defmodule AshEnterprise.Canonical.CalendarEvent do
  @moduledoc """
  One calendar event (dogfood §11's first vertical), projected from
  SourceObjects with `external_system: "calendar"` — today the deterministic
  fixture tap (`AshEnterprise.Ingestion.FixtureTap`), later the operator's real
  calendar via Nango (ADR 0011).

  `external_uid` is the provider's own cross-system id (Google's `iCalUID`),
  unique per provider — the id invitations and cancellations reference, as
  distinct from `external_id`, which is the sync row id the tap paginates by.

  Projection-derived, so `archival?`/`lifecycle?` are opted out for the same
  reasons as `AshEnterprise.Canonical.Person`: replay reconstructs, soft delete
  would ghost the upsert identity, and an event's lifecycle is the provider's.
  That lifecycle is `status` (confirmed / tentative / cancelled), projected
  from the provider payload: a cancellation flips it rather than deleting the
  row.

  `title` and `location` are content: sealed under the erasure scope of the
  SourceObject the event was projected from (ADR 0024,
  `AshEnterprise.Erasure.Changes.SealUnderScope`), and read as
  `AshEnterprise.Erasure.Shredded` once that scope is shredded.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    extra_extensions: [AshCloak]

  postgres do
    table "canonical_calendar_events"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:title, :location]
    decrypt_by_default([:title, :location])
    encrypt_nil?(false)
  end

  changes do
    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:title, :location]},
      on: [:create, :update]
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      # No max_length on a sealed attribute: a failed constraint renders the
      # value into the error message (Ash's InvalidArgument), and errors reach
      # traces, Oban and BPMN incidents, which no shred reaches (ADR 0024).
      description "The event's summary line."
    end

    attribute :starts_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Start, per the source payload."
    end

    attribute :ends_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "End, per the source payload."
    end

    attribute :location, :string do
      public? true
      # Unbounded for the same reason as `title`.
      description "Where, when the event says."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :confirmed
      constraints one_of: [:confirmed, :tentative, :cancelled]

      description """
      The provider's event status. A cancelled event keeps its row (and its
      title and times) with this set to `:cancelled`, so a deleted meeting
      never silently vanishes and never looks live.
      """
    end

    attribute :external_uid, :string do
      public? true
      constraints max_length: 512
      description "The provider's cross-system event id (iCalUID), unique per provider."
    end

    attribute :external_system, :string do
      public? true
      constraints max_length: 64
      description "Source-of pair: which external system the event was projected from."
    end

    attribute :external_id, :string do
      public? true
      constraints max_length: 512
      description "Source-of pair: that system's id for the event."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organizer, AshEnterprise.Canonical.Person do
      public? true
      attribute_public? true
      allow_nil? true

      description "The Person projected from the organizer's email. Nil when the payload had no address."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true

      description "The scope of the SourceObject this event was projected from; its key seals the content."
    end
  end

  identities do
    identity :unique_external, [:external_system, :external_id]
    identity :unique_provider_uid, [:external_system, :external_uid]
  end

  actions do
    defaults [:read]

    read :by_external do
      description """
      Look up the canonical row projected from one raw SourceObject.

      KNOWN GAP (E1 review, fix owned by a dedicated E1 follow-up):
      SourceObject identity is `[external_system, external_id]` *without* the
      stream, and this lookup inherits that shape — two streams sharing an
      external id would land on one row here. The calendar projector
      disambiguates by filtering `source_metadata["stream"] == "events"` when
      it selects its raw rows; until the identity is fixed, lookups cannot.
      """

      get? true
      argument :system, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false

      filter expr(external_system == ^arg(:system) and external_id == ^arg(:id))
    end

    create :upsert_from_source do
      description "The replay write path: upsert on the source identity."

      accept [
        :title,
        :starts_at,
        :ends_at,
        :location,
        :status,
        :external_uid,
        :external_system,
        :external_id,
        :organizer_id,
        :erasure_scope_id,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_external

      upsert_fields [
        :encrypted_title,
        :starts_at,
        :ends_at,
        :encrypted_location,
        :status,
        :external_uid,
        :organizer_id,
        :erasure_scope_id
      ]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
