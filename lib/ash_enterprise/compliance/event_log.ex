defmodule AshEnterprise.Compliance.EventLog do
  @moduledoc """
  The compliance event log the KYC projector drains.

  ## Why this is not `AshEnterprise.Audit.EventLog`

  The central audit trail is the right *shape* — it is an AshEvents log — but
  not the right *contract*:

    * **Its schema is owned by the tamper-evident chain.** Adding columns to
      serve a consumer's SELECT is a change to the most sensitive resource in
      the system, made for someone else's convenience (ADR 0002).
    * **The projector engine's drain names its wake-up columns.** The
      schemaless select in `AshEvents.Projections.Server` reads
      `practice_id`/`user_id` by name; the audit log carries neither, and the
      chain trigger would need reviewing if it ever did.
    * **The audiences differ.** The audit log records every platform write and
      must never prune. The compliance log carries KYC review events with
      their fact payload, and is the compliance program's own consumable.

  A compliance event is appended explicitly by
  `AshEnterprise.Compliance.Changes.RecordKycEvent`, which runs on the KYC
  review action — the shape mirrors what `AshEvents.Events` generates for
  wrapped actions, because a resource can carry only one event log and the
  platform resources already carry the central one.

  ## Shape notes

  `user_id` and `practice_id` exist because the drain selects them by name;
  `user_id` doubles as the legacy actor attribution when the ingester writes
  with `resolve_actor/1` metadata. `organization_id` is stamped from the
  event metadata by `ExtractMetadataFields` so tenant-scoped queries do not
  need to open the JSON.
  """

  use Ash.Resource,
    domain: AshEnterprise.Compliance,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "compliance_events"
    repo AshEnterprise.Repo
  end

  event_log do
    advisory_lock_key_generator AshEvents.AdvisoryLockKeyGenerator.Default
  end

  actions do
    # Reads for surfaces and tests; a single explicit, primary, append-only
    # create for `AshEnterprise.Compliance.Kyc`. The AshEvents transformer
    # would otherwise add a non-primary `:create`, and an event appender that
    # has to name its action is one copy-paste away from appending nowhere.
    defaults [:read]

    create :create do
      primary? true

      accept [
        :version,
        :data,
        :metadata,
        :record_id,
        :resource,
        :action,
        :action_type,
        :occurred_at
      ]
    end
  end

  # The one compliance resource this application owns outright, and the one
  # place the role model governs the compliance plane directly. The fourteen
  # `ash_compliance` resources cannot carry this application's policy block —
  # they are the package's modules, and Spark builds policies into a resource
  # at its own compile time (ADR 0035 records the reversal path: when the
  # package ships resource macros the way `ash_bpmn` does, they instantiate on
  # the platform base and inherit the full union of grants).
  #
  # So the envelope here is: the append-only create is governed by the same
  # union of grants as everything else (the seeded Administrator role holds
  # every privilege; the projector engine and the drain append under the
  # system actor, which bypasses by role attribution exactly as it does for
  # the audit log), and reads are granted like any other resource's.
  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy always() do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end

  changes do
    change {AshEvents.Projections.Events.Changes.ExtractMetadataFields,
            fields: [
              {:organization_id, cast: :uuid},
              {:practice_id, cast: :uuid},
              {:user_id, cast: :uuid, overwrite?: false}
            ]},
           on: [:create]

    change AshEvents.Projections.Events.Changes.NotifyProjectors, on: [:create]
  end

  attributes do
    attribute :organization_id, :uuid, public?: true
    attribute :practice_id, :uuid, public?: true
    attribute :user_id, :uuid, public?: true
  end
end
