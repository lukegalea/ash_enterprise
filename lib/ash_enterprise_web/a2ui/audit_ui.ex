defmodule AshEnterpriseWeb.A2ui.AuditUI do
  @moduledoc """
  Audit trail — the central audit log (`AshEnterprise.Audit.EventLog`),
  newest first: when, which resource and action, which record and who. An
  entry's detail links to its lineage run (the same correlation id), so the
  question "what operation wrote this, and what else did it touch" is one
  click away.

  Shows only the structural fields (`event_log public_fields`): never an
  entry's `data`, `changed_attributes` or `metadata`. Read-only, as the
  signed-in person in their tenant, under their audit read grant.

  Served at `/app/audit`; `/app/r/audit/:id` deep-links one entry.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Audit.EventLog
    surface_id "audit"
    title "Audit trail"
    record_label "audit entry"
    spec_version "1.0"

    context :entry do
      resource AshEnterprise.Audit.EventLog
      picker false
    end

    query :trail do
      sortable [:occurred_at]
      filters [:resource, :action_type, :correlation_id]
      range_filters [:occurred_at]
      default_sort occurred_at: :desc
      page_size 25
      max_page_size 100
    end

    component :table do
      fields [:occurred_at, :resource, :action, :action_type, :record_id, :run]
      read_action :read
      query :trail
      select_context :entry
    end

    component :detail, :entry_detail do
      context :entry

      fields [
        :occurred_at,
        :resource,
        :action,
        :action_type,
        :record_id,
        :user_id,
        :correlation_id,
        :run
      ]
    end

    field :occurred_at do
      label "When"
    end

    field :resource do
      label "Resource"
    end

    field :action do
      label "Action"
    end

    field :action_type do
      label "Kind"
    end

    field :record_id do
      label "Record"
    end

    field :user_id do
      label "By"
      link {:users, :user_id}
    end

    field :correlation_id do
      label "Correlation id"
    end

    # Present only for a reader with a lineage read grant, and while the run
    # is inside its retention window.
    field :run do
      label "Lineage run"
      link :lineage_run
      link_label :label
    end
  end
end
