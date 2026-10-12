defmodule AshEnterprise.Integration.Calendar.Sync do
  @moduledoc """
  The calendar vertical's entry points, as generic actions — policy-gated,
  traced and correlated like every other action.

    * `request_sync(%{linked_account_id: id?})` — enqueue one
      `AshEnterprise.Integration.Calendar.SyncWorker` job for one of the
      actor's own Google Calendar accounts. Unique per account: a request
      while a step is queued returns the queued job.
    * `run_step(%{linked_account_id: id?})` — run one bounded step now, as the
      actor (what the worker calls). Returns the step summary.
    * `reset_sync(%{linked_account_id: id?})` — the explicit sync-reset: every
      cursor of the account forgets its tokens; the next step full-syncs.

  `linked_account_id` is a routing hint naming one of the actor's own linked
  accounts; it is optional when the actor has exactly one active Google
  Calendar account. It is never a connection id.

  No table, ownership `:none`: the policy question is "may this actor run
  calendar syncs", answered by a Global read grant on this resource. Which
  account is reachable is then decided by the actor's own `LinkedAccount`
  policies, inside the action.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration.Calendar,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false

  # Generic actions only and no rows, but the platform's system attributes are
  # still fields, which trips Ash's primary-key check for stored resources.
  resource do
    require_primary_key? false
  end

  actions do
    action :request_sync, :map do
      description "Enqueue one calendar sync step for one of the actor's own linked accounts."

      argument :linked_account_id, :uuid do
        allow_nil? true

        description "Which of the actor's own Google Calendar accounts. Optional when there is one."
      end

      run AshEnterprise.Integration.Calendar.Actions.RequestSync
    end

    action :run_step, :map do
      description "Run one bounded calendar sync step now, as the actor."

      argument :linked_account_id, :uuid do
        allow_nil? true

        description "Which of the actor's own Google Calendar accounts. Optional when there is one."
      end

      run AshEnterprise.Integration.Calendar.Actions.RunStep
    end

    action :reset_sync, :map do
      description """
      The explicit sync-reset: forget every calendar's sync and page tokens for
      one account, so the next step is a full sync. Wrong-cursor recovery is
      always this action, never a silent rewind.
      """

      argument :linked_account_id, :uuid do
        allow_nil? true

        description "Which of the actor's own Google Calendar accounts. Optional when there is one."
      end

      run AshEnterprise.Integration.Calendar.Actions.ResetSync
    end
  end

  code_interface do
    define :request_sync
    define :run_step
    define :reset_sync
  end
end
