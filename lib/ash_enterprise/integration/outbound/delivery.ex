defmodule AshEnterprise.Integration.Outbound.Delivery do
  @moduledoc """
  One audit event owed to one outbound webhook endpoint, and what became of sending it
  (ADR 0075). Created by the endpoint's fan-out
  (`AshEnterprise.Integration.Outbound.Changes.FanOut`), sent by the `:deliver` trigger
  through the declared operation `AshEnterprise.Integration.Outbound.Receiver.deliver`.

  | `state` | Meaning |
  |---|---|
  | `pending` | owed; sent when `next_attempt_at` passes and its endpoint is active |
  | `delivered` | the receiver answered 2xx |
  | `refused` | nothing was sent: the disclosure gate or the egress guard refused, or the endpoint's secret is gone. Never retried |
  | `dead` | the first send and five retries all failed (1 minute, 5 minutes, 30 minutes, 2 hours and 12 hours apart) |

  The identity `(endpoint_id, event_id)` makes a second fan-out of one event a no-op, and the
  event id is the `webhook-id` every attempt carries, so a receiver that dedupes on it sees
  one event however many times it is sent.

  It holds no payload: the CloudEvent is rebuilt from the row on each attempt, and carries
  only the record's id. Not audited, for the reason `Bpmn.Dispatch` is not: the audit event
  is the fact, and this row is the bookkeeping of telling someone about it. A person's
  `redeliver` is the one write that is not machinery, and it is the endpoint's to answer.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    ownership: :organization_owned,
    lifecycle?: false,
    audit?: false,
    archival?: false,
    machinery_only: [:enqueue, :deliver],
    extra_extensions: [AshOban]

  alias AshEnterprise.Integration.Outbound.Changes
  alias AshEnterprise.Platform.SystemActor

  postgres do
    table "integration_outbound_deliveries"
    repo AshEnterprise.Repo

    references do
      reference :endpoint, on_delete: :delete
    end

    custom_indexes do
      index [:state, :next_attempt_at]
    end
  end

  oban do
    triggers do
      trigger :deliver do
        action :deliver

        where expr(
                state == :pending and next_attempt_at <= now() and
                  exists(endpoint, status == :active)
              )

        read_action :read
        queue :webhooks
        scheduler_cron "* * * * *"
        max_attempts 3
        use_tenant_from_record? true
        actor_persister :none
        default_actor SystemActor.oban()
        worker_module_name AshEnterprise.Integration.Outbound.Delivery.DeliverWorker
        scheduler_module_name AshEnterprise.Integration.Outbound.Delivery.DeliverScheduler
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_id, :uuid do
      allow_nil? false
      public? true
      description "The audit event this delivery tells the endpoint about; the webhook-id."
    end

    attribute :event_sequence, :integer do
      allow_nil? false
      public? true
    end

    attribute :event_type, :string do
      allow_nil? false
      public? true
    end

    attribute :subject_id, :string do
      allow_nil? false
      public? true
      description "The id of the record the event is about."
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :delivered, :refused, :dead]
    end

    attribute :attempts, :integer do
      allow_nil? false
      public? true
      default 0
    end

    attribute :last_status, :integer do
      public? true
      description "The receiver's HTTP status on the last attempt, when it answered."
    end

    attribute :last_reason, :string do
      public? true
      description "A short code for the last failure: never a response body."
    end

    attribute :next_attempt_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end

    attribute :delivered_at, :utc_datetime_usec do
      public? true
    end
  end

  relationships do
    belongs_to :endpoint, AshEnterprise.Integration.Outbound.Endpoint do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_event, [:endpoint_id, :event_id]
  end

  actions do
    defaults [:read]

    create :enqueue do
      description "Owe one audit event to one endpoint. A second enqueue of it is a no-op."

      accept [
        :endpoint_id,
        :event_id,
        :event_sequence,
        :event_type,
        :subject_id,
        :occurred_at
      ]
    end

    update :deliver do
      description "Send the event once, and record the outcome or schedule the next attempt."
      accept []
      require_atomic? false
      # The send is an HTTP call: no transaction is held open across it.
      transaction? false
      change Changes.Deliver
    end

    update :redeliver do
      description "Send a delivered, refused or dead event again, from the first attempt."
      accept []
      require_atomic? false

      validate attribute_does_not_equal(:state, :pending) do
        message "is already waiting to be sent"
      end

      change set_attribute(:state, :pending)
      change set_attribute(:attempts, 0)
      change set_attribute(:last_reason, nil)
      change set_attribute(:last_status, nil)
      change set_attribute(:next_attempt_at, &DateTime.utc_now/0)
    end
  end
end
