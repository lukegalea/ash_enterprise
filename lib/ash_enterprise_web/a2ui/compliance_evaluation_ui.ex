defmodule AshEnterpriseWeb.A2ui.ComplianceEvaluationUI do
  @moduledoc """
  A2UI surface over the append-only evaluation log — the drill-down behind a
  finding: which bundle decided, on which fact snapshot, with what missing.

  Read-only: evaluations are never rewritten, only appended. The `:read`
  action is all the surface can offer, and that is the point.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshCompliance.Resources.ComplianceEvaluation
    surface_id "compliance-evaluations"

    query :default do
      sortable [:control_id, :outcome, :subject_id]
      page_size 25
    end

    component :table do
      fields [
        :control_id,
        :subject_id,
        :outcome,
        :bundle_hash,
        :missing_facts,
        :correlation_id,
        :source_event_id,
        :evaluated_at
      ]

      read_action :read
      query :default

      row_layout do
        title :control_id
        badge :outcome
        meta [:subject_id, :bundle_hash, :missing_facts, :source_event_id, :evaluated_at]
        columns 2
      end
    end

    field :bundle_hash do
      label "Bundle"
    end

    field :source_event_id do
      label "Event"
    end
  end
end
