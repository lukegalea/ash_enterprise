defmodule AshEnterpriseWeb.A2ui.MdmBatchUI do
  @moduledoc """
  Import batches (ADR 0054): every CS import as a card in the lane of its
  status — open, staging, matching, review, closed, failed. Opening a batch
  (its card's link, or the picker) shows its counters, why it failed if it
  did, the mapping version it pinned, its staged rows with their status, and
  the rows of its upload that did not land, each with its spreadsheet row
  number and why (`AshEnterprise.Mdm.ImportRowRefusal`), exportable as CSV.

  Read-only by construction: a batch moves through its lanes by the
  pipeline's own machinery (`AshEnterprise.Mdm.BatchWorker`), so the board
  offers no transitions. Imports start in ImportLive, which links here.

  Served at `/app/mdm/batches`; `/app/r/mdm_batches/:id` deep-links one batch.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Mdm.ImportBatch)
    surface_id("mdm_batches")
    title("Import batches")
    record_label("import batch")

    # Chosen from a card (`select_context` on the board) or by searching here;
    # `/app/r/mdm_batches/:id` still deep-links one from elsewhere.
    context :batch do
      resource(AshEnterprise.Mdm.ImportBatch)
      label("Open a batch")
      option_label(:source_slug)
      option_search([:source_slug])
      option_limit(25)
    end

    query :lane do
      sortable([:created_on])
      default_sort(created_on: :desc)
      page_size(10)
      max_page_size(50)
    end

    query :staged do
      sortable([:status, :created_on])
      default_sort(created_on: :asc)
      page_size(25)
      max_page_size(100)
    end

    query :refused do
      sortable([:row_number])
      default_sort(row_number: :asc)
      page_size(25)
      max_page_size(100)
    end

    component :table, :batches do
      display(:board)
      fields([:source_slug, :counts_summary, :opened])
      read_action(:read)
      query(:lane)
      select_context(:batch)

      row_layout do
        title(:source_slug)
        meta([:counts_summary, :opened])
      end

      sections do
        scope_by(:status)
        values([:open, :staging, :matching, :review, :closed, :failed])
      end
    end

    component :detail, :batch_detail do
      context(:batch)
      fields([:source_slug, :status, :opened, :counts_summary, :failure_reason, :mapping])
    end

    component :table, :staged_rows do
      resource(AshEnterprise.Mdm.StagedRecord)
      fields([:label, :mapped_email, :status, :findings_text])
      query(:staged)
      context_filter(batch_id: :batch)
      require_context([:batch])

      row_layout do
        title(:label)
        badge(:status)
        meta([:mapped_email, :findings_text])
      end
    end

    # The error report a person acts on: fix these rows in the file and import
    # it again (the rows that landed re-land as no-ops).
    component :table, :refused_rows do
      resource(AshEnterprise.Mdm.ImportRowRefusal)
      fields([:row_number, :reason])
      query(:refused)
      context_filter(batch_id: :batch)
      require_context([:batch])

      export do
        filename("refused-rows.csv")
        columns([:row_number, :reason])
      end
    end

    field :source_slug do
      label("Dataset")
    end

    field :counts_summary do
      label("Counts")
    end

    field :opened do
      label("Opened")
    end

    field :failure_reason do
      label("Why it failed")
    end

    field :mapping do
      label("Mapping")
      link(:mapping)
      link_label(:stream)
    end

    field :label do
      label("Staged row")
    end

    field :mapped_email do
      label("Email")
    end

    field :findings_text do
      label("Findings")
    end

    field :row_number do
      label("Row")
    end

    field :reason do
      label("Why it did not land")
    end
  end
end
