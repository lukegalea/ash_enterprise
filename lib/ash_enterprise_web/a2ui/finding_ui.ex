defmodule AshEnterpriseWeb.A2ui.FindingUI do
  @moduledoc """
  A2UI surface over the KYC finding projection — the admin's answer to "who
  is breaching what, and why".

  Read-only by construction: the finding resource carries only reads plus the
  engine's own `upsert_grain`/`apply_projection_ops`, neither of which a
  surface may call. The experience layer derives the affordances from the
  actions that exist, so this surface renders `View` and no `Edit`.

  `explanation` is the whole point of the row: the rule message or the
  missing-evidence summary, projected at evaluation time. `status` is badged
  so compliant/noncompliant/unknown read without a legend.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshCompliance.Resources.Finding
    surface_id "compliance-findings"

    query :default do
      sortable [:status, :severity, :control_id, :subject_id]
      default_sort status: :asc
      page_size 25
    end

    component :table do
      fields [
        :control_id,
        :subject_type,
        :subject_id,
        :status,
        :severity,
        :breach_count,
        :explanation
      ]

      read_action :read
      query :default

      row_layout do
        title :control_id
        badge :status
        meta [:severity, :breach_count]
        columns 1
      end
    end

    field :explanation do
      label "Why"
    end
  end
end
