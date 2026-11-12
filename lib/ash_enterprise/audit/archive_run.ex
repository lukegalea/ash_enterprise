defmodule AshEnterprise.Audit.ArchiveRun do
  @moduledoc """
  One retention step, recorded: an archive of a run of rows out of a hot table, or a purge of
  a run of rows out of an archive (`AshEnterprise.Audit.Retention`).

  A row says what moved (`store`, `kind`, the chain and sequence range for the audit log),
  how many rows, the SHA-256 `digest` of their hashes in order, and whether the copy
  verified. A failed verification is recorded too, with its `reason`: nothing was deleted,
  and the row is the evidence that the step was tried and refused.

  A purge of the audit archive also records the `tail_hash` of the last purged event. The
  chain verifier (`AshEnterprise.Audit.Chain`) starts the chain from that anchor, so the
  rows that remain still verify after the oldest have gone.

  Append-only and machinery-only: `record` is run by the `oban` system actor
  (`AshEnterprise.Security.ActionReach`), there is no update or destroy, and reading follows
  the grant union. Audited like any platform write, so the log holds its own retention
  history.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Audit,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:record]

  postgres do
    table "audit_archive_runs"
    repo AshEnterprise.Repo

    custom_indexes do
      index [:store, :kind, :chain_organization_id, :to_sequence],
        name: "audit_archive_runs_anchor_index"
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "Record one retention step. Machinery only."
      primary? true

      accept [
        :store,
        :kind,
        :status,
        :chain_organization_id,
        :from_sequence,
        :to_sequence,
        :row_count,
        :digest,
        :tail_hash,
        :cutoff,
        :reason
      ]
    end

    read :latest_purge_anchor do
      description "The newest verified purge of one audit chain: where the remaining chain starts."

      argument :chain_organization_id, :uuid, allow_nil?: true

      get? true

      # The chain with no tenant is a chain too: nil matches nil here, not nothing.
      filter expr(
               store == :audit_events and kind == :purge and status == :verified and
                 (chain_organization_id == ^arg(:chain_organization_id) or
                    (is_nil(^arg(:chain_organization_id)) and is_nil(chain_organization_id)))
             )

      prepare build(sort: [to_sequence: :desc], limit: 1)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :store, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:audit_events, :evidence_artifacts]
      description "Which hot table the rows came from."
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:archive, :purge]
      description "`archive`: hot table to archive. `purge`: out of the archive, after 400 days."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:verified, :failed]
      description "`failed` means the copy did not verify and nothing was deleted."
    end

    attribute :chain_organization_id, :uuid do
      public? true
      description "For the audit log, the tenant chain; nil is the chain with no tenant."
    end

    attribute :from_sequence, :integer, public?: true
    attribute :to_sequence, :integer, public?: true

    attribute :row_count, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :digest, :string do
      public? true
      description "SHA-256 over the moved rows' hashes, in order."
    end

    attribute :tail_hash, :string do
      public? true

      description "For an audit purge, the hash of the last purged event: the remaining chain's anchor."
    end

    attribute :cutoff, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "Rows older than this were eligible."
    end

    attribute :reason, :string do
      public? true
      constraints max_length: 500
      description "Why a failed step refused."
    end

    create_timestamp :inserted_at
  end
end
