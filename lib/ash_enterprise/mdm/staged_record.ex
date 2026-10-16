defmodule AshEnterprise.Mdm.StagedRecord do
  @moduledoc """
  One landed source row, mapped into canonical shape by the batch's pinned
  mapping — the thing matching, banding and the steward's side-by-side all
  read. One per (batch, SourceRecord); re-running a batch re-derives
  nothing that already exists (bizev's temporal idempotency handles the
  landing side, this identity the staging side).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false

  postgres do
    table "mdm_staged_records"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :batch_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :source_record_id, :uuid do
      allow_nil? false
      public? true
      description "The bizev SourceRecord this staging derives from."
    end

    attribute :mapped, :map do
      public? true

      description "Canonical-shaped key/values from the evaluator fold; nil when validation failed."
    end

    attribute :validation_findings, :map do
      public? true
      description "Per-row findings: evaluator rule errors, required-field misses."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :staged

      constraints one_of: [
                    :staged,
                    :matched,
                    :admitted,
                    :review,
                    :omitted,
                    :created,
                    :merged,
                    :rejected
                  ]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :one_per_source_record, [:batch_id, :source_record_id]
  end

  calculations do
    # What a row reads as on the batch surface: the mapped values, never the
    # landed source row.
    calculate :label, :string, expr(mapped[:name] || mapped[:email] || "Unmapped row") do
      public? true
      description "The staged row by mapped name, else email."
    end

    calculate :mapped_email, :string, expr(mapped[:email]) do
      public? true
      description "The staged row's mapped email."
    end

    calculate :findings_text, :string, AshEnterprise.Mdm.Calculations.FindingsText do
      public? true
      description "The row's validation findings as text, or nil when it mapped cleanly."
    end
  end

  actions do
    read :read do
      primary? true
    end

    create :stage do
      accept [:batch_id, :source_record_id, :mapped, :validation_findings, :status]
    end

    update :update do
      accept [:mapped, :validation_findings, :status]
    end
  end

  code_interface do
    define :by_id, action: :read, get_by: [:id]
  end
end
