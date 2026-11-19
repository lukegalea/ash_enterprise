defmodule AshEnterpriseWeb.A2ui.WebhookDeliveriesUI do
  @moduledoc """
  Outbound webhook deliveries (`AshEnterprise.Integration.Outbound.Delivery`, ADR 0075): each
  event owed to an endpoint, newest first, with its state, attempts, the receiver's last
  status and a short reason. A delivery holds no payload. **Redeliver** sends a delivered,
  refused or dead event again from its first attempt, with the same `webhook-id`.

  Served at `/app/webhook-deliveries`; the inherited grants decide who sees what.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Integration.Outbound.Delivery
    surface_id "webhook_deliveries"
    title "Outbound webhook deliveries"
    record_label "delivery"

    context :delivery do
      resource AshEnterprise.Integration.Outbound.Delivery
      picker false
    end

    query :default do
      search_fields [:event_type, :subject_id]
      sortable [:occurred_at, :state, :attempts]
      default_sort occurred_at: :desc
      page_size 25
    end

    component :table do
      fields [
        :event_type,
        :subject_id,
        :state,
        :attempts,
        :last_status,
        :last_reason,
        :occurred_at
      ]

      read_action :read
      query :default
      select_context :delivery
      row_actions [:redeliver]

      row_layout do
        title :event_type
        badge :state

        badge_text pending: "Pending",
                   delivered: "Delivered",
                   refused: "Refused",
                   dead: "Dead"

        meta [:subject_id, :attempts, :last_status, :last_reason, :occurred_at]
        columns 2
      end
    end

    component :detail, :delivery_detail do
      context :delivery

      fields [
        :event_type,
        :subject_id,
        :event_id,
        :state,
        :attempts,
        :last_status,
        :last_reason,
        :next_attempt_at,
        :delivered_at,
        :occurred_at
      ]
    end

    action :redeliver do
      label "Redeliver"
      visible_when state: [:delivered, :refused, :dead]
    end

    field :event_type do
      label "Event type"
    end

    field :subject_id do
      label "Record"
    end

    field :event_id do
      label "Event id"
    end

    field :last_status do
      label "Last status"
    end

    field :last_reason do
      label "Last reason"
    end

    field :next_attempt_at do
      label "Next attempt"
    end

    field :delivered_at do
      label "Delivered"
    end

    field :occurred_at do
      label "Occurred"
    end
  end
end
