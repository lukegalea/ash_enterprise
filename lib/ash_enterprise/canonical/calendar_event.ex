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

  ## Temporal (ADR 0049, PROD-47)

  Every version of an event is kept: each re-projection that changes it
  opens a new version from the write's instant, and the one before stays
  readable as of any instant it was valid. A plain read is the calendar now;
  `as_of:` reads it as it was known then, agenda windows included
  (`AshEnterprise.Canonical.Preparations.AgendaWindow`).
  `AshEnterprise.Canonical.CalendarHistory` walks a week's versions for the
  calendar's time scrubber. Every version is sealed under the same scope
  key, so a shred reaches all of them. The attendee joins are not temporal:
  they say who is invited now.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    extra_extensions: [AshCloak]

  # Every version of an event is kept (ADR 0049, PROD-47): a reschedule, a
  # rename or a cancellation closes the version valid until then and opens a
  # new one, so the calendar can be read as it was known at any instant
  # ("what did my week look like last Monday, before the reschedules").
  # Writes are always "now": nothing on this resource writes as of another
  # instant (ADR 0049 invariant 7).
  temporal do
    strategy :context
    attribute :valid_at
  end

  postgres do
    table "canonical_calendar_events"
    repo AshEnterprise.Repo

    # The generator drops this key on a temporal table; the cutover's
    # `canonical_calendar_events_foreign_keys` statement keeps it, with this
    # same `ON DELETE RESTRICT`.
    references do
      reference :erasure_scope, on_delete: :restrict
    end

    # Fills the period of the rows the table held before it became temporal;
    # the cutover then sets each one's lower bound (`TemporalCutover`).
    migration_defaults valid_at: "fragment(\"tstzrange(now(), NULL)\")"

    # The generator adds the period but does not convert an existing table's
    # key and identities, and drops the foreign keys to ordinary tables; the
    # cutover does the rest. See `AshEnterprise.Canonical.CalendarEvent.TemporalCutover`.
    custom_statements do
      statement :canonical_calendar_events_temporal do
        up AshEnterprise.Canonical.CalendarEvent.TemporalCutover.temporal_up()
        down AshEnterprise.Canonical.CalendarEvent.TemporalCutover.temporal_down()
        # The attendees' foreign key to the plain key goes first.
        after_tables ["canonical_event_attendees"]
      end

      statement :canonical_calendar_events_foreign_keys do
        up AshEnterprise.Canonical.CalendarEvent.TemporalCutover.foreign_keys_up()
        down AshEnterprise.Canonical.CalendarEvent.TemporalCutover.foreign_keys_down()
      end
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
      temporal_keys {:valid_at, nil}
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      attribute_public? true
      attribute_writable? true

      description "The scope of the SourceObject this event was projected from; its key seals the content."
      temporal_keys {:valid_at, nil}
    end

    has_many :attendees, AshEnterprise.Canonical.EventAttendee do
      public? true
      destination_attribute :event_id
      description "Who is invited, with their responses (derived joins)."
      temporal_keys {:valid_at, nil}
    end

    many_to_many :people, AshEnterprise.Canonical.Person do
      public? true
      through AshEnterprise.Canonical.EventAttendee
      join_relationship :attendees
      source_attribute_on_join_resource :event_id
      destination_attribute_on_join_resource :person_id
      description "The people invited to this event."
    end
  end

  identities do
    identity :unique_external, [:external_system, :external_id]
    identity :unique_provider_uid, [:external_system, :external_uid]
  end

  aggregates do
    count :attendee_count, :attendees do
      public? true
      description "How many people are invited."
    end
  end

  actions do
    defaults [:read]

    update :mdm_repoint do
      description """
      The person merge's write (ADR 0054): this event's organizer moves to the golden
      record a merge folded its person into, and back on the unmerge
      (`AshEnterprise.Mdm.PersonJoins`). Machinery only, never typed in.
      """

      accept [:organizer_id]
    end

    # The agenda windows the daily-loop surfaces read (Today, Calendar; ACP
    # `today` / `calendar`). Cut in the display zone, in start order — see
    # `AshEnterprise.Canonical.Preparations.AgendaWindow`.
    read :today do
      description "Events overlapping today, in the operator's display zone, in start order."
      prepare {AshEnterprise.Canonical.Preparations.AgendaWindow, window: :today}
    end

    read :tomorrow do
      description "Events overlapping tomorrow, in the operator's display zone, in start order."
      prepare {AshEnterprise.Canonical.Preparations.AgendaWindow, window: :tomorrow}
    end

    read :this_week do
      description "Events overlapping today and the next six days, in start order."
      prepare {AshEnterprise.Canonical.Preparations.AgendaWindow, window: :this_week}
    end

    read :upcoming do
      description "Events from now to fourteen days out, in start order."
      prepare {AshEnterprise.Canonical.Preparations.AgendaWindow, window: :upcoming}
    end

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
      description """
      The replay write path: upsert on the source identity. A change opens a
      new version from the write's instant; a write that changes nothing
      opens none.
      """

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

      argument :attendees, {:array, :map} do
        allow_nil? true

        description """
        The attendees the projector resolved: `%{person_id, response_status}`
        maps. Derived into `AshEnterprise.Canonical.EventAttendee` rows in the
        same transaction; omitted (nil), the event's attendees are left as
        they are.
        """
      end

      # A write that changes nothing keeps the current version (and opens
      # none). First, while the sealed values are still in the clear.
      change AshEnterprise.Canonical.Changes.KeepUnchangedVersion
      change AshEnterprise.Canonical.Changes.DeriveAttendees

      # On a match the upsert splits the version valid now: the old values
      # stay valid until this write, the new ones from it (ADR 0049).
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
        :erasure_scope_id,
        # Named because ash_postgres's temporal upsert, unlike its plain one,
        # does not refresh update defaults on a match: without them a new
        # version would carry the old version's write time, and its business
        # event (whose `occurred_at` is `updated_at`) the wrong instant.
        :updated_at,
        :modified_on
      ]

      # The business events this write implies, in its transaction (ADR 0051).
      change {AshEnterprise.BusinessEvents.Changes.Derive, subject: :calendar_event}
    end
  end

  calculations do
    calculate :time_range,
              :string,
              {AshEnterprise.Canonical.Calculations.EventTime, format: :range} do
      public? true
      description "`09:00–09:30`, in the operator's display zone."
    end

    calculate :when, :string, {AshEnterprise.Canonical.Calculations.EventTime, format: :span} do
      public? true
      description "`Mon 12 Oct · 09:00–09:30`, in the operator's display zone."
    end

    calculate :organizer_label,
              :string,
              {AshEnterprise.Canonical.Calculations.PersonLabel, relationship: :organizer} do
      public? true
      description "The organizer's name, else their address."
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
    define :today
  end
end
