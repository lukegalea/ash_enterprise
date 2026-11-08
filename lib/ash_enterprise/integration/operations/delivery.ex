defmodule AshEnterprise.Integration.Operations.Delivery do
  @moduledoc """
  A provider webhook delivery, recorded once (`AshOperations.Webhook.Ingress`, ADR 0063). The
  attributes, the identity and the `record`, `awaiting_follow_up` and `volume_report` actions come
  from `AshOperations.Resources.Delivery`, instantiated on this application's base resource; the
  `mark_followed_up` action's settle (`FollowUp`, layered on through `settle_changes`), the trigger and the policies are this application's.

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

  `record` and `mark_followed_up` are machinery-only (ADR 0059): only the `oban`
  system actor runs them, the ingress as it records the delivery and the `:follow_up` trigger as
  it settles it.
  Tenantless and unowned (`tenant?: false`, `ownership: :none`), like the other bookkeeping of
  the integration domain; audited, so a delivery is a recorded fact.
  """

  alias AshEnterprise.Integration.Operations.Changes.FollowUp
  alias AshEnterprise.Platform.SystemActor

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:record, :mark_followed_up],
    extra_extensions: [AshOban]

  use AshOperations.Resources.Delivery,
    subject_required?: true,
    settle_changes: [FollowUp]

  postgres do
    table "integration_provider_webhook_deliveries"
    repo AshEnterprise.Repo

    # The columns the shared resource added to rows that already exist.
    migration_defaults received_at: ~S|fragment("(now() AT TIME ZONE 'utc')")|,
                       signature_verdict: ~S|"valid"|
  end

  oban do
    triggers do
      # A delivery nobody has followed up. The ingress enqueues nothing itself, so the
      # scheduler is the path; it runs every minute.
      trigger :follow_up do
        action :mark_followed_up
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
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
