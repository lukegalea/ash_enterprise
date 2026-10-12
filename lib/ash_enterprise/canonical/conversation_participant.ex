defmodule AshEnterprise.Canonical.ConversationParticipant do
  @moduledoc """
  A person taking part in a conversation: a first-class join between
  `AshEnterprise.Canonical.Conversation` and `AshEnterprise.Canonical.Person`.

  A **derived fact**. The Gmail and Slack projectors already resolve each
  thread's participants to the owner's people (`participants["person_ids"]`,
  sealed inside the conversation); this row states the same thing as a
  queryable link, so a person's conversations are a join rather than a
  decrypt-and-scan. It is written by
  `AshEnterprise.Canonical.Changes.DeriveParticipants` inside the
  conversation's own upsert, so a replay re-derives it and a re-projected
  thread's participant list converges on the projector's.

  ## Personal data and erasure (ADR 0042, ADR 0024)

  **Owner-only**, like its parents (`AshEnterprise.Security.Privilege.owner_only?/1`).
  It holds ids only — nothing sealed — so it is *not* under the conversation's
  erasure scope, and who-talks-to-whom would survive a key destroy if the row
  stayed. It does not: shredding a scope deletes every participant row of the
  conversations sealed under it (`AshEnterprise.Erasure.Changes.DestroyScopeKey`).
  Listed in `docs/runbooks/crypto-shredding.md`.

  `audit?: false` for the same reason as `AshEnterprise.Canonical.EventAttendee`:
  an immutable audit event per join would outlive the shred that deletes it,
  and the row is reconstructable from the raw landings.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    audit?: false

  postgres do
    table "canonical_conversation_participants"
    repo AshEnterprise.Repo

    references do
      reference :conversation, on_delete: :delete
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

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, AshEnterprise.Canonical.Conversation do
      allow_nil? false
      public? true
      attribute_public? true
      description "The conversation taken part in."
    end

    belongs_to :person, AshEnterprise.Canonical.Person do
      allow_nil? false
      public? true
      attribute_public? true
      description "Who takes part in it."
    end
  end

  identities do
    identity :unique_participation, [:conversation_id, :person_id]
  end

  actions do
    defaults [:read]

    create :derive do
      description """
      Record one participation, upserting on `(conversation, person)` so a
      replay converges. Written by the conversation's projection.
      """

      accept [
        :conversation_id,
        :person_id,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_participation
      # Nothing to refresh on a conflict: the pair is the whole fact. Writing
      # the person id back keeps the upsert a real `ON CONFLICT DO UPDATE`, so
      # it returns the row.
      upsert_fields [:person_id]
    end

    destroy :forget do
      description """
      Drop a participation: the person is no longer among the thread's
      participants, or the conversation's erasure scope was shredded.
      """
    end
  end
end
