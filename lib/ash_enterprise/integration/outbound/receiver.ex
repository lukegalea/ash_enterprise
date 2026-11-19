defmodule AshEnterprise.Integration.Outbound.Receiver do
  @moduledoc """
  An outbound webhook receiver, declared as a provider (`AshOperations`, ADR 0075): one
  generic action, `deliver`, that POSTs one CloudEvent to one tenant's registered endpoint.

  The receiver contract is `priv/webhooks/outbound.openapi.json`, pinned by sha-256 here and
  published in the runbook (`docs/runbooks/outbound-webhooks.md`): the structured
  CloudEvent body and the Standard Webhooks headers.

  Which endpoint is a `:context` param, `endpoint_id`: the transport
  (`AshEnterprise.Integration.Outbound.Transport`) resolves its URL through the egress guard
  and opens its signing secret, and neither ever becomes a request field. `message_id` (the
  audit event id) is the `webhook-id` the transport signs.

  `deliver` is idempotent: receivers dedupe on `webhook-id`, so a 5xx or a timeout is sent
  again rather than reported ambiguous. It discloses, so the disclosure gate
  (`AshEnterprise.Integration.Outbound.DisclosureGate`) decides before anything is sent;
  `disclosure_ref` is the endpoint id.

  Machinery only: the `oban` system actor runs it, from the delivery's `:deliver` trigger.
  Tier 3 and confined like the rest of the integration domain.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:deliver],
    extensions: [AshOperations]

  # Generic actions only and no rows, but the platform's system attributes are still
  # fields, which trips Ash's primary-key check for stored resources.
  resource do
    require_primary_key? false
  end

  operations do
    provider :outbound_webhook
    transport AshEnterprise.Integration.Outbound.Transport
    spec "priv/webhooks/outbound.openapi.json"
    spec_sha256 "c20a3ab1044c3fbd667f2df3350ca0ef34b3f7bbbc5c85b0376bb5c2965a133e"
    disclosure_gate AshEnterprise.Integration.Outbound.DisclosureGate
    telemetry_prefix [:ash_enterprise, :outbound_webhook, :request]

    operation :deliver, :post, "/" do
      description "POST one CloudEvent to one endpoint. Receivers dedupe on webhook-id."
      idempotent? true
      response :none
      timeout 10_000
      discloses? true

      param :endpoint_id, :uuid, in: :context, allow_nil?: false
      param :message_id, :string, in: :context, allow_nil?: false

      param :specversion, :string, in: :body, allow_nil?: false
      param :event_id, :uuid, in: :body, as: "id", allow_nil?: false
      param :source, :string, in: :body, allow_nil?: false
      param :type, :string, in: :body, allow_nil?: false
      param :subject, :string, in: :body
      param :time, :utc_datetime_usec, in: :body
      param :datacontenttype, :string, in: :body
      param :data, :map, in: :body
    end
  end
end
