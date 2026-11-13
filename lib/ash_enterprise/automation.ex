defmodule AshEnterprise.Automation do
  @moduledoc """
  What a tenant's recipes react to when the thing that happened is not an audited
  tenant write.

  | Resource | What it is |
  |---|---|
  | `Occurrence` | A fact recorded into a tenant's audit chain so that a subscription can match it: a user deactivated, a sign-in refused, a break-glass session approved, an API key issued, an inbound alert |
  | `Incident` | The alerts that share a key, from the first one that fired until it closes: a duplicate alert joins the open incident |

  `AshEnterprise.Automation.Occurrences` is the only writer of occurrences, and
  `AshEnterprise.Automation.Incidents` of incidents. Inbound alerts reach the first through
  `AshEnterprise.Automation.AlertWebhook`.
  """

  use Ash.Domain, otp_app: :ash_enterprise

  resources do
    resource AshEnterprise.Automation.Occurrence do
      define :record_occurrence, action: :record
      define :list_occurrences, action: :read
    end

    resource AshEnterprise.Automation.Incident do
      define :open_incident, action: :open
      define :join_incident, action: :join
      define :resolve_incident_series, action: :resolve_series, args: [:series]
      define :close_incident, action: :close, args: [:reason]
      define :list_incidents, action: :read
    end
  end
end
