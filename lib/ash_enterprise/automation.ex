defmodule AshEnterprise.Automation do
  @moduledoc """
  What a tenant's recipes react to when the thing that happened is not an audited
  tenant write.

  | Resource | What it is |
  |---|---|
  | `Occurrence` | A fact recorded into a tenant's audit chain so that a subscription can match it: a user deactivated, a sign-in refused, a break-glass session approved, an API key issued, an inbound alert |

  `AshEnterprise.Automation.Occurrences` is the only writer. Inbound alerts reach it through
  `AshEnterprise.Automation.AlertWebhook`.
  """

  use Ash.Domain, otp_app: :ash_enterprise

  resources do
    resource AshEnterprise.Automation.Occurrence do
      define :record_occurrence, action: :record
      define :list_occurrences, action: :read
    end
  end
end
