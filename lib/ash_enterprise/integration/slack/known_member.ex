defmodule AshEnterprise.Integration.Slack.KnownMember do
  @moduledoc """
  A workspace member the Slack sync has seen through one linked account, and
  when their profile (`users.info`) was last fetched.

  It exists so a sync step does not spend a `users.info` call on every author
  of every new message, and so a member seen in a step that ran out of lookup
  budget is not forgotten: a member is *noted* when first seen (`fetched_at`
  nil) and is *due* until fetched, then again once `fetched_at` is older than
  the configured refresh interval. The profile itself is landed through
  `Landing.land/2`, under the linked account's scope; this row holds **only the
  Slack user id and a timestamp**.

  Opt-outs as `AshEnterprise.Integration.Slack.ConversationCursor`'s, for the
  same reasons: sync bookkeeping, written only after the linked account was
  resolved under the actor's policies, deleted with the linked account.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false

  postgres do
    table "integration_slack_known_members"
    repo AshEnterprise.Repo

    references do
      reference :linked_account, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :slack_user_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
      description "Slack's member id (U…, W…)."
    end

    attribute :fetched_at, :utc_datetime_usec do
      public? true

      description "When the member's profile was last fetched and landed; nil while it never has been."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :linked_account, AshEnterprise.Integration.LinkedAccount do
      allow_nil? false
      public? true
      attribute_public? true
      domain AshEnterprise.Integration
    end
  end

  identities do
    identity :unique_member, [:linked_account_id, :slack_user_id]
  end

  actions do
    defaults [:read]

    read :for_account do
      description "Every member noted for one linked account."
      argument :linked_account_id, :uuid, allow_nil?: false
      filter expr(linked_account_id == ^arg(:linked_account_id))
      prepare build(sort: [slack_user_id: :asc])
    end

    read :due do
      description """
      Members of one linked account whose profile is due: never fetched, or
      fetched before `stale_before`. Never-fetched first, then oldest first.
      """

      argument :linked_account_id, :uuid, allow_nil?: false
      argument :stale_before, :utc_datetime_usec, allow_nil?: false

      filter expr(
               linked_account_id == ^arg(:linked_account_id) and
                 (is_nil(fetched_at) or fetched_at < ^arg(:stale_before))
             )

      prepare build(sort: [fetched_at: :asc_nils_first, slack_user_id: :asc])
    end

    create :note_seen do
      description "Note a member the sync has seen. A no-op for a member already noted."
      accept [:linked_account_id, :slack_user_id]
      upsert? true
      upsert_identity :unique_member
      # Nothing to refresh: an already-noted member keeps its fetched_at.
      upsert_fields [:slack_user_id]
    end

    create :mark_fetched do
      description "Record that a member's profile was fetched (upsert)."
      accept [:linked_account_id, :slack_user_id, :fetched_at]
      upsert? true
      upsert_identity :unique_member
      upsert_fields [:fetched_at]
    end
  end

  code_interface do
    define :for_account, args: [:linked_account_id]
    define :due, args: [:linked_account_id, :stale_before]
    define :note_seen
    define :mark_fetched
  end
end
