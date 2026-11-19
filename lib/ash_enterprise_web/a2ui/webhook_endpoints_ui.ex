defmodule AshEnterpriseWeb.A2ui.WebhookEndpointsUI do
  @moduledoc """
  Outbound webhook endpoints (`AshEnterprise.Integration.Outbound.Endpoint`, ADR 0075): the
  tenant's registered URLs, what each is sent, and whether it is active, disabled or failing
  and why. Edit changes what an endpoint is sent; **Disable** stops it, and **Enable** turns a
  disabled or failing one back on.

  Registering an endpoint and rotating its secret are not offered here: each hands back the
  signing secret once, as the action's result, and this surface has no way to show a result
  once. They are run through the code interface
  (`AshEnterprise.Integration.register_webhook_endpoint/2`,
  `rotate_webhook_secret/2`), as `docs/runbooks/outbound-webhooks.md` describes.

  Served at `/app/webhook-endpoints`; the inherited grants decide who sees and changes what.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Integration.Outbound.Endpoint
    surface_id "webhook_endpoints"
    title "Webhook endpoints"
    record_label "endpoint"

    context :endpoint do
      resource AshEnterprise.Integration.Outbound.Endpoint
      picker false
    end

    query :default do
      search_fields [:url]
      sortable [:url, :status, :created_on]
      default_sort created_on: :desc
      page_size 25
    end

    component :table do
      fields [:url, :status, :status_reason, :event_types, :consecutive_dead]
      read_action :read
      query :default
      select_context :endpoint
      row_actions [:disable, :enable]

      row_layout do
        title :url
        badge :status
        badge_text active: "Active", disabled: "Disabled", failing: "Failing"
        meta [:status_reason, :event_types, :consecutive_dead]
        columns 2
      end
    end

    component :detail, :endpoint_detail do
      context :endpoint

      fields [
        :url,
        :description,
        :event_types,
        :status,
        :status_reason,
        :consecutive_dead,
        :created_on
      ]
    end

    component :form do
      fields [:description, :event_types]
      update_action :update
    end

    action :disable do
      label "Disable"
      visible_when status: [:active, :failing]
    end

    action :enable do
      label "Enable"
      visible_when status: [:disabled, :failing]
    end

    field :url do
      label "URL"
    end

    field :event_types do
      label "Event types"
    end

    field :status_reason do
      label "Why"
    end

    field :consecutive_dead do
      label "Dead letters in a row"
    end

    field :created_on do
      label "Registered"
    end
  end
end
