defmodule AshEnterprise.Canonical.CommitmentScan do
  @moduledoc """
  One record the commitment extractor has read (PROD-18): a sent message or
  an ended meeting, which proposer read it with which instrument, and how
  many proposals came of it — none included (ADR 0047: a learner's record
  keeps its negative results). It is also what makes the sweep read each
  record once: a record with a scan is not read again.

  Structure only, never content: the record is named by type and id, the
  proposals it led to are `Canonical.Task` rows in status `:proposed`
  (sealed under the source's erasure scope), and nothing here says what the
  message or meeting said.

  Written by the proposer system actor (`AshEnterprise.Canonical.Commitments`)
  in the same transaction as the proposals it records. Owned by the person
  the record belongs to, so it is theirs to read and nobody else's without a
  role.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "canonical_commitment_scans"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :source_type, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description ~s{The record read, by resource ("Elixir.AshEnterprise.Canonical.Message").}
    end

    attribute :source_id, :uuid do
      allow_nil? false
      public? true
      description "That record's id."
    end

    attribute :found, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
      description "How many proposals the read produced (0 is a result, not a failure)."
    end

    attribute :proposer, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "Which proposer read it, with its version (`gmail_commitments/1`)."
    end

    attribute :instrument, :string do
      allow_nil? false
      public? true
      constraints max_length: 255

      description """
      What it read with: the in-zone model's label and zone
      (`openai:splash @ zone-a`), or `deterministic`.
      """
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :one_scan_per_record, [:source_type, :source_id]
  end

  actions do
    defaults [:read]

    create :record do
      description "Record one read: written by the proposer with the proposals it made."

      accept [
        :source_type,
        :source_id,
        :found,
        :proposer,
        :instrument,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]
    end
  end

  code_interface do
    define :record
  end
end
