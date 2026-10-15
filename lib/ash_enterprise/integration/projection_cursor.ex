defmodule AshEnterprise.Integration.ProjectionCursor do
  @moduledoc """
  How far one linked account's landed records have been projected into the
  canonical model: the Gmail and Slack syncs' "pending projection" watermark
  (`AshEnterprise.Canonical.Projections.Pending`).

  A sync step's provider cursor (`Gmail.SyncState`, `Slack.ConversationCursor`)
  moves on as soon as a page has **landed**. Projection runs after landing, at
  the end of the step, so it keeps its own position: `projected_through` is
  the newest `SourceObject.fetched_at` among the records the last successful
  projection covered. The next step projects what landed after it. A
  projection that fails leaves the watermark where it was, so nothing landed is
  ever skipped: the next step projects it again (projection is an upsert on the
  source identity, so re-projecting converges).

  Nil means nothing has been projected through the step yet: the first step
  projects everything the account has landed.

  **Holds no content**: a linked account id and two timestamps.

  Opt-outs as `AshEnterprise.Integration.Slack.ConversationCursor`'s, for the
  same reasons: sync bookkeeping (`ownership: :none`, `tenant?: false`),
  written only after the linked account was resolved under its owner's
  policies, overwritten rather than soft-deleted, not audited (one write per
  step; it records a position, not a decision), and deleted with the linked
  account (`on_delete: :delete`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false

  postgres do
    table "integration_projection_cursors"
    repo AshEnterprise.Repo

    references do
      reference :linked_account, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :projected_through, :utc_datetime_usec do
      public? true

      description "The newest SourceObject.fetched_at the last successful projection covered; nil before the first."
    end

    attribute :projected_at, :utc_datetime_usec do
      public? true
      description "When the watermark last moved."
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
    identity :unique_linked_account, [:linked_account_id]
  end

  actions do
    defaults [:read]

    read :for_account do
      description "The watermark of one linked account, or nothing before its first projection."
      get? true
      argument :linked_account_id, :uuid, allow_nil?: false
      filter expr(linked_account_id == ^arg(:linked_account_id))
    end

    create :advance do
      description """
      Upsert the watermark. The caller passes the position it has projected
      through; it never moves backwards (`Pending` compares before it writes).
      """

      accept [:linked_account_id, :projected_through, :projected_at]
      upsert? true
      upsert_identity :unique_linked_account
      upsert_fields [:projected_through, :projected_at]
    end
  end

  code_interface do
    define :for_account, args: [:linked_account_id], not_found_error?: false
    define :advance
  end
end
