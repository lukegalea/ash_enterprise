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
        :organization_id,
        :control_id,
        :subject_id,
        :outcome,
        :bundle_revision,
        :correlation_id,
        :evaluated_at
      ]

      read_action :read
      query :default

      row_layout do
        title :control_id
        badge :outcome
        meta [:evaluated_at]
        columns 1
      end
    end
  end
end
