defmodule AshEnterpriseWeb.A2ui.MdmBatchUI do
  @moduledoc """
  Import batches (ADR 0054): every CS import as a card in the lane of its
  status — open, staging, matching, review, closed, failed. Opening a batch
  (its card's link, or the picker) shows its counters, why it failed if it
  did, the mapping version it pinned, and its staged rows with their status.

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

    # A board selects nothing per card (lanes are expanded tables), so a
    # batch is chosen here or by its card's link, which deep-links it.
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

    component :table, :batches do
      display(:board)
      fields([:source_slug, :counts_summary, :opened])
      read_action(:read)
      query(:lane)

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

    field :source_slug do
      label("Dataset")
      link({:mdm_batches, :id})
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
  end
end
