defmodule AshEnterprise.Mdm.ImportBatch do
  @moduledoc """
  One CS import: the unit of lineage. `correlation_id` is minted at :open
  and threads stage → match → band → merge → export; every audit row the
  batch causes carries it, which is what makes "where did this golden
  record come from" one query (ADR 0054 §11).

  `mapping_content_hash` is pinned at open — a batch never re-maps
  mid-flight; a changed mapping is a new batch.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false

  postgres do
    table "mdm_import_batches"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: [:open, :staging, :matching, :review, :closed, :failed]
    end

    attribute :mapping_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :mapping_content_hash, :string do
      allow_nil? false
      public? true
      description "Pinned at open from the mapping's content_hash."
    end

    attribute :source_slug, :string do
      allow_nil? false
      public? true
      constraints max_length: 128

      description "The customer/dataset slug — a STRING; it segments the bizev stream's external_ids."
    end

    attribute :rule_set_id, :uuid do
      public? true
      description "Pinned at open from the active MatchRuleSet for the mapping's target resource."
    end

    attribute :rule_set_content_hash, :string do
      public? true
    end

    attribute :counts, :map do
      public? true
      default %{}

      description "Running counters: landed, staged, validation_failed, candidates, admitted, review, omitted, created, merged."
    end

    attribute :correlation_id, :uuid do
      allow_nil? false
      public? true
      description "The lineage run id — minted at open, never changed."
    end

    attribute :failure_reason, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    read :read do
      primary? true
    end

    create :open do
      description "Opens a batch against a mapping version, pinning its hash and minting the correlation id."
      accept [:mapping_id, :source_slug]

      change AshEnterprise.Mdm.Changes.OpenBatch
    end

    update :begin_staging do
      accept []
      # Idempotent: a re-run finds the batch already staged/matching and
      # re-derives nothing.
      validate attribute_in(:status, [:open, :staging, :matching])
      change set_attribute(:status, :staging)
    end

    update :begin_matching do
      accept []
      validate attribute_in(:status, [:staging, :matching])
      change set_attribute(:status, :matching)
    end

    update :close do
      description "The human flow finished: staged, matched, reviewed."
      accept []
      validate attribute_in(:status, [:staging, :matching, :review])
      change set_attribute(:status, :closed)
    end

    update :fail do
      accept [:failure_reason]
      validate attribute_does_not_equal(:status, :closed)
      change set_attribute(:status, :failed)
    end
  end

  code_interface do
    define :open, action: :open
    define :by_id, action: :read, get_by: [:id]
  end
end
