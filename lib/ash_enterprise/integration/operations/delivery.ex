defmodule AshEnterprise.Integration.Operations.Delivery do
  @moduledoc """
  A provider webhook delivery, recorded once (`AshOperations.Webhook.Ingress`, ADR 0063).

  A webhook is a nudge, so a delivery holds only what the follow-up needs: the `provider`, the
  provider's redelivery-stable `dedup_key`, and `subject_id`, the id the provider says to look
  at. It holds no payload, no header and no tenant: the tenant is learned later, from an
  authenticated read of the provider, never from the delivery. The identity
  `(provider, dedup_key)` is what makes a redelivery a no-op.

  | `state` | Meaning |
  |---|---|
  | `received` | recorded, not yet followed up |
  | `followed_up` | the follow-up found activations waiting on a reconcile and enqueued it |
  | `ignored` | the follow-up found nothing waiting, or the provider's answer named no one |

  `receive` and `follow_up` are machinery-only (ADR 0059): only the `oban` system actor runs
  them, the ingress as it records the delivery and the `:follow_up` trigger as it settles it.
  Tenantless and unowned (`tenant?: false`, `ownership: :none`), like the other bookkeeping of
  the integration domain; audited, so a delivery is a recorded fact.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:receive, :follow_up],
    extra_extensions: [AshOban]

  alias AshEnterprise.Integration.Operations.Changes.FollowUp
  alias AshEnterprise.Platform.SystemActor

  require Ash.Query

  postgres do
    table "integration_provider_webhook_deliveries"
    repo AshEnterprise.Repo
  end

  oban do
    triggers do
      # A delivery nobody has followed up. The ingress enqueues nothing itself, so the
      # scheduler is the path; it runs every minute.
      trigger :follow_up do
        action :follow_up
        where expr(state == :received)
        read_action :read
        queue :ingestion
        scheduler_cron "* * * * *"
        max_attempts 3
        actor_persister :none
        default_actor SystemActor.oban()
        worker_module_name AshEnterprise.Integration.Operations.Delivery.FollowUpWorker
        scheduler_module_name AshEnterprise.Integration.Operations.Delivery.FollowUpScheduler
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
      constraints max_length: 64
    end

    attribute :dedup_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 128
    end

    attribute :subject_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 128
      description "The id the provider says to look at (an activation id). Untrusted until read."
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :received
      constraints one_of: [:received, :followed_up, :ignored]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :delivery, [:provider, :dedup_key]
  end

  actions do
    defaults [:read]

    create :receive do
      description "Record a delivery once, by the provider's own redelivery-stable key."
      accept [:provider, :dedup_key, :subject_id]
    end

    update :follow_up do
      description """
      Read the provider about the delivery's subject, and enqueue the reconcile of the
      activations that wait on it. It decides nothing: the reconcile asks the provider again.
      """

      accept []
      require_atomic? false
      change FollowUp
    end
  end

  @doc "Whether a delivery with this provider and key is already recorded."
  @spec recorded?(String.t(), String.t()) :: boolean()
  def recorded?(provider, dedup_key) do
    __MODULE__
    |> Ash.Query.filter(provider == ^provider and dedup_key == ^dedup_key)
    |> Ash.exists?(authorize?: false)
  end
end
