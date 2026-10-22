defmodule AshEnterprise.Canonical.EventAttendee do
  @moduledoc """
  A person attending a calendar event, with their response: a first-class
  join between `AshEnterprise.Canonical.CalendarEvent` and
  `AshEnterprise.Canonical.Person`.

  A **derived fact**. The calendar projectors land the event and its
  attendees' `Person` rows from the provider payload; this row is what the
  canonical model concludes from them — that this person was asked to this
  meeting, and how they answered. It is written by
  `AshEnterprise.Canonical.Changes.DeriveAttendees` inside the event's own
  upsert, so a replay re-derives it and a re-projected event's attendee list
  converges on the payload's (attendees who were removed lose their row).

  ## Personal data and erasure (ADR 0042, ADR 0024)

  **Owner-only**, like its parents (`AshEnterprise.Security.Privilege.owner_only?/1`):
  the event's owner reads it and nobody else. It holds ids and a response
  status — nothing sealed — so it is *not* under the event's erasure scope.
  Who-meets-whom therefore survives a key destroy unless the row goes too, and
  it does: shredding a scope deletes every attendee row of the events sealed
  under it (`AshEnterprise.Erasure.Changes.DestroyScopeKey`). Listed in
  `docs/runbooks/crypto-shredding.md`.

  `audit?: false`, deliberately: the audit log is immutable (ADR 0020), so an
  audited join would keep who-meets-whom forever, past the shred that deletes
  the row. The row is reconstructable from the raw landings, so nothing is lost
  that a replay cannot rebuild. `archival?`/`lifecycle?` are off for the same
  reasons as every projected canonical row.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    audit?: false

  postgres do
    table "canonical_event_attendees"
    repo AshEnterprise.Repo

    # `CalendarEvent` is temporal, so `event_id` has no foreign key (and no
    # cascade): its `id` alone is not unique, one row per version, and a key
    # cannot point at a temporal table from one that is not. Nothing
    # destroys events; a shred deletes their joins itself.
    references do
      reference :person, on_delete: :delete
    end

    # A person's side of the join (their events, their conversations); the
    # identity's unique index leads with the other parent.
    custom_indexes do
      index [:person_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :response_status, :atom do
      public? true
      constraints one_of: [:needs_action, :accepted, :tentative, :declined]

      description """
      How they answered the invitation, per the provider (`responseStatus`).
      Nil when the source does not say.
      """
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :event, AshEnterprise.Canonical.CalendarEvent do
      allow_nil? false
      public? true
      attribute_public? true
      description "The event attended."
      temporal_keys {nil, :valid_at}
    end

    belongs_to :person, AshEnterprise.Canonical.Person do
      allow_nil? false
      public? true
      attribute_public? true
      description "Who attends it."
    end
  end

  identities do
    identity :unique_attendance, [:event_id, :person_id]
  end

  actions do
    defaults [:read]

    update :mdm_repoint do
      description """
      The person merge's write (ADR 0054): this attendance moves to the golden
      record a merge folded its person into, and back on the unmerge
      (`AshEnterprise.Mdm.PersonJoins`). Machinery only, never typed in.
      """

      accept [:person_id]
    end

    create :derive do
      description """
      Record one attendance, upserting on `(event, person)` so a replay
      converges. Written by the event's projection, never typed in.
      """

      accept [
        :event_id,
        :person_id,
        :response_status,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_attendance
      upsert_fields [:response_status]
    end

    destroy :forget do
      description """
      Drop an attendance: the person left the event's attendee list, or the
      event's erasure scope was shredded.
      """
    end
  end

  calculations do
    calculate :response_label,
              :string,
              expr(
                cond do
                  response_status == :accepted -> "Accepted"
                  response_status == :tentative -> "Maybe"
                  response_status == :declined -> "Declined"
                  response_status == :needs_action -> "No reply"
                  true -> ""
                end
              ) do
      public? true
      description "Their answer, in words."
    end
  end
end
