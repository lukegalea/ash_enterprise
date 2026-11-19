defmodule AshEnterprise.Mdm.ImportRowRefusal do
  @moduledoc """
  One row of an uploaded file that did not land, and why: the error report a
  person can act on (`AshEnterprise.Mdm.BulkImport`). The batch board lists a
  batch's refusals beside its staged rows and exports them as CSV.

  `row_number` is the row as a spreadsheet shows it: the header is row 1, so
  the first data row is row 2. `reason` names the rule the row broke (a
  malformed row, a residency the landing region does not admit) and never
  quotes the row's values beyond the residency it declared.

  Written by the batch worker alone (`machinery_only`), once per row: a
  re-run of the same batch rewrites the same row's reason, never a second row.
  `audit?: false`: a refusal is the import's own diagnostic, already threaded
  to its batch (and the batch's correlation id), and it records no change to
  anyone's data; an audit event per refused row would double the write for a
  fact the row itself answers.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    machinery_only: [:record]

  postgres do
    table "mdm_import_row_refusals"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :batch_id, :uuid do
      allow_nil? false
      public? true
      description "The import batch whose upload carried the row."
    end

    attribute :row_number, :integer do
      allow_nil? false
      public? true
      constraints min: 2
      description "The row as a spreadsheet numbers it: the header is row 1."
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints max_length: 500
      description "Why the row did not land, without the row's values."
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :one_per_row, [:batch_id, :row_number]
  end

  actions do
    read :read do
      primary? true
    end

    create :record do
      description "Records why one uploaded row did not land; a re-run rewrites the reason."
      accept [:batch_id, :row_number, :reason]
      upsert? true
      upsert_identity :one_per_row
      upsert_fields [:reason]
    end
  end
end
