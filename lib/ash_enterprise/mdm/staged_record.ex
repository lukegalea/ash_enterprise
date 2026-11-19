defmodule AshEnterprise.Mdm.StagedRecord do
  @moduledoc """
  One landed source row, mapped into canonical shape by the batch's pinned
  mapping — the thing matching, banding and the steward's side-by-side all
  read. One per (batch, SourceRecord); re-running a batch re-derives
  nothing that already exists (bizev's temporal idempotency handles the
  landing side, this identity the staging side).

  ## Personal data (ADR 0024)

  `mapped` holds the row's canonical values, a person's name and address among
  them, in plaintext, and it is audited: the audit event of each staging keeps
  them, and the audit log is immutable. Erasing a person
  (`AshEnterprise.Erasure.PersonErasure`) deletes the staged rows whose mapped
  address is theirs (`erase`), but not those audit events.
  `docs/runbooks/crypto-shredding.md` lists them as a residual. A pseudonymised copy
  (ADR 0032) replaces `mapped` and `validation_findings`; the audit events are copied
  empty.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    # Only the erase-person act calls it, inside its own authorized transaction.
    machinery_only: [:erase]

  postgres do
    table "mdm_staged_records"
    repo AshEnterprise.Repo
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml). `mapped`
  # holds the row's canonical values, a person's name and address among them, and a
  # finding can quote the value a rule could not read (`{:cast_failed, type, value}`), so
  # both are replaced. The row, its status and its links to the batch and the landing stay.
  greenmask do
    transform(:mapped, :replace, value: "{}")
    transform(:validation_findings, :replace, value: ~s({"errors": [], "warnings": []}))
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

    destroy :erase do
      description """
      Removes a staged row for the erase-person act (`AshEnterprise.Erasure.PersonErasure`).
      Never part of ordinary staging. A real delete: staged rows are not archived.
      """
    end
  end

  code_interface do
    define :by_id, action: :read, get_by: [:id]
  end
end
