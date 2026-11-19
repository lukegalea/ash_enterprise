defmodule AshEnterprise.Integration.Outbound.CloudEvent do
  @moduledoc """
  The CloudEvents 1.0 structured event a delivery sends: a thin nudge.

      {
        "specversion": "1.0",
        "id": "<the audit event id>",
        "source": "/organizations/<organization id>",
        "type": "ash_enterprise.team.create",
        "subject": "<the record's id>",
        "time": "<when the event was written, ISO 8601>",
        "datacontenttype": "application/json",
        "data": {"id": "<the record's id>"}
      }

  It carries the record's id and nothing else of the record. The receiver reads the record
  through the API with its own key, so it learns only what that key may read, and nothing
  here has to evaluate a policy per delivery. ADR 0063: a webhook is a nudge.
  """

  alias AshEnterprise.Integration.Outbound.Delivery

  @doc "The operation arguments for one delivery: the CloudEvent's fields."
  @spec arguments(Delivery.t()) :: map()
  def arguments(%Delivery{} = delivery) do
    %{
      specversion: "1.0",
      event_id: delivery.event_id,
      source: "/organizations/#{delivery.organization_id}",
      type: delivery.event_type,
      subject: delivery.subject_id,
      time: delivery.occurred_at,
      datacontenttype: "application/json",
      data: %{"id" => delivery.subject_id}
    }
  end
end
