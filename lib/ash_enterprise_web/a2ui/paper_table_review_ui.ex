defmodule AshEnterpriseWeb.A2ui.PaperTableReviewUI do
  @moduledoc """
  Clause tables: the `paper.clause.*` decision versions that put wording in a
  tenant's documents (`AshEnterprise.Decisions.Definition`, read through
  `paper_clause_tables`) and, before anyone publishes a draft, which issued
  documents it would gain or lose the clause for (R4).

  Measure impact replays the draft over the key's recorded evaluations as the
  person measuring (`AshDecisions.Replay`), maps each case back to the
  document it decided, and stores the report on the draft. Publishing refuses
  unless that report is for this exact version and no document in it failed
  (`AshEnterprise.Documents.Paper.ClauseTableVerifier`). The Impact report
  lists each affected document with the table's answer before and after.
  Tables are drafted and published in the decisions designer.

  Served at `/app/documents/clause-tables`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Decisions.Definition
    surface_id "paper_table_review"
    title "Clause tables"
    record_label "clause table"

    component :table do
      fields [:key, :version, :status, :impact_summary]
      read_action :paper_clause_tables
      row_actions [:measure_impact]
    end

    component :report, :impact_changes do
      action :impact_changes
      fields [:candidate, :document, :issued, :outcome, :before, :after, :note]
    end

    action :measure_impact do
      label "Measure impact"
    end

    field :key do
      label "Decision"
    end

    field :impact_summary do
      label "Impact"
    end

    field :candidate do
      label "Draft"
    end

    field :document do
      label "Document (run)"
    end

    field :issued do
      label "Issued"
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
