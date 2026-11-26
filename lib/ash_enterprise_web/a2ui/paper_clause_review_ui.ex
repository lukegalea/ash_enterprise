defmodule AshEnterpriseWeb.A2ui.PaperClauseReviewUI do
  @moduledoc """
  Document wording: the tenant's clause versions
  (`AshEnterprise.Documents.PaperClause`) and, before a checker admits a
  draft, what it would change in documents already issued (R4).

  The table lists every version with where its impact report stands
  (`impact_summary`: not measured, stale, errored, or its counts). Measure
  impact renders the tenant's recent issued documents that carry the clause
  again with the draft in its place and stores the report on the draft; Admit
  refuses unless that report is for this exact version and no document in it
  failed, and refuses the drafter whatever the report says (maker-checker).
  The Impact report below lists each changed document with its before and
  after block text, read from the stored reports, never measured on read.

  Served at `/app/documents/document-wording`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Documents.PaperClause
    surface_id "paper_clause_review"
    title "Document wording"
    record_label "clause"

    component :table do
      fields [:key, :locale, :version, :status, :impact_summary]
      read_action :read
      row_actions [:measure_impact, :admit]
    end

    component :report, :impact_changes do
      action :impact_changes
      fields [:candidate, :document, :issued, :outcome, :block, :before, :after, :note]
    end

    action :measure_impact do
      label "Measure impact"
    end

    action :admit do
      label "Admit"
    end

    field :key do
      label "Clause"
    end

    field :impact_summary do
      label "Impact"
    end

    field :candidate do
      label "Draft"
    end

    field :issued do
      label "Issued"
    end

    field :block do
      label "Block"
    end

    field :before do
      label "Before"
    end

    field :after do
      label "After"
    end

    field :note do
      label "Note"
    end
  end
end
