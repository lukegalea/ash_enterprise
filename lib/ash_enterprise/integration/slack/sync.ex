defmodule AshEnterprise.Integration.Slack.Sync do
  @moduledoc """
  The entry points to the Slack sync, as ordinary policy-gated actions run by
  the human whose account it is.

    * `request_sync(%{linked_account_id: id}, actor: user)` — enqueue one
      `AshEnterprise.Integration.Slack.SyncWorker` step for the actor's linked
      account. Returns `%{job_id, linked_account_id, conflict?}`; `conflict?`
      is true when a step for that account is already queued or running (the
      worker is unique per account), and nothing new was enqueued.
    * `sync_step(%{linked_account_id: id}, actor: user)` — run one step inline
      and return its summary (counts only). For operators and tests; the
      schedule goes through `request_sync`.

  `linked_account_id` may be omitted when the actor has exactly one active
  Slack account. Either way the account is resolved from the **actor's own**
  linked accounts under their policies (ADR 0011 deviation 1) — naming someone
  else's account resolves nothing. The Nango connection is never an input.

  Generic actions map to the `:read` verb; this resource owns no rows, so the
  grant that authorizes it is Global read on `AshEnterprise.Integration.Slack.Sync`
  (plus Basic read on `LinkedAccount` and Global read on
  `AshEnterprise.Integration.Slack`, which the step itself needs).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration.Slack.Domain,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false

  # Generic actions only and no rows, but the platform's system attributes are
  # still fields, which trips Ash's primary-key check (as on the edge's
  # operation resources).
  resource do
    require_primary_key? false
  end

  actions do
    action :request_sync, :map do
      description "Enqueue one Slack sync step for one of the actor's own linked accounts."
      argument :linked_account_id, :uuid, allow_nil?: true
      run AshEnterprise.Integration.Slack.Sync.RequestSync
    end

    action :sync_step, :map do
      description "Run one Slack sync step inline, as the actor; returns counts only."
      argument :linked_account_id, :uuid, allow_nil?: true
      run AshEnterprise.Integration.Slack.Sync.RunStep
    end
  end

  code_interface do
    define :request_sync
    define :sync_step
  end
end
