defmodule AshEnterprise.Legacy.UserBackfill do
  @moduledoc """
  Projects one row of the legacy read model into `AshEnterprise.Accounts.ProjectedUser`.

  `project_row/1` is the entry point of `mix ash_enterprise.legacy.project`, the one-off that
  establishes the starting state of `projected_users` and the repair for anything the live path
  missed. It is **not** the live path and is not an `Ash.Notifier`.

  ## The live path is the change ledger, not a notification

  `Legacy.User` has `ledger?(true)`, so a legacy write reaches this application like this:

      INSERT INTO legacy.users ...              -- the legacy application, unmodified
        -> strangler_ledger_legacy_users        (AFTER trigger: a durable ledger row,
                                                 in the legacy application's own transaction,
                                                 then pg_notify 'wake:<id>')
        -> AshStrangler.Listener                (started in AshEnterprise.Application;
                                                 nudges the drain and does nothing else)
        -> AshEnterprise.Ledger.UserDrainWorker (claim, ingest, mark: one transaction)
        -> AshEnterprise.Ledger.UserIngestion   (the ProjectedUser upsert and the KYC events)
        -> COMMIT
        -> AshEnterprise.Ledger.UserAnnouncer   (one notification per drained event)
        -> Ash.Notifier.PubSub on Legacy.User
        -> "legacy_users:*" on the endpoint's PubSub
        -> the surface at /app/legacy-users refreshes

  `projected_users` is therefore kept current by the drain. This module used to be an
  `Ash.Notifier` on `Legacy.User` that upserted from the notification the listener dispatched;
  a `ledger?` source never dispatches one, so it never ran, and it was removed rather than left
  to project every row a second time beside the drain.

  ## Why the backfill still has its own entry point

  The ledger records *changes*. A row that has not changed since the ledger trigger was installed
  has no event, so it has never been projected -- and the rows in a legacy database that has been
  running for fifteen years are overwhelmingly of that kind. This reads the compatibility view,
  which shows every row, and projects each one.

  ## One entry point, and why that is not a style preference

  `project_row/1` is the only way the backfill projects a row, and it hands the row to
  `AshEnterprise.Legacy.UserProjection.project/1`, which the drain's ingestion calls too. That one
  function aligns `lifecycle_status` through the platform's own state machine: a legacy user in
  `suspended` or `passive` must not land in `projected_users` carrying `lifecycle_status: :active`.
  An earlier version of the task rebuilt the attribute map itself and called the upsert directly,
  which skipped the transition, and the drain did the same, so the value a row ended up with
  depended on which path had written it last.

  `project_row/1` **returns** `{:error, reason}` rather than swallowing it, because the backfill
  wants to report a refused row and a swallowed error gives it nothing to report.

  Its audit rows say where they came from: `project_row/1` passes `legacy_path`, `legacy_source_table`
  and `legacy_id` as `ash_events_metadata`, the backfill's counterpart of the drain's `ledger_*` keys.
  """

  alias AshEnterprise.Legacy.UserProjection

  @doc """
  Projects one legacy row and aligns the projected row's lifecycle.

  Returns `:ok` or `{:error, reason}`. Does not rescue: the caller reports a refused row.
  """
  @spec project_row(struct()) :: :ok | {:error, term()}
  def project_row(row) do
    with {:ok, _projected} <- project(row), do: :ok
  end

  @doc """
  Projects one legacy row like `project_row/1`, and returns the projected row. `path` is
  the `legacy_path` its audit rows carry: `"backfill"`, or `"reconcile"` for the nightly
  repair (`AshEnterprise.Legacy.ReconcileWorker`), which records the row's compliance
  events from it.
  """
  @spec project(struct(), String.t()) :: {:ok, struct()} | {:error, term()}
  def project(row, path \\ "backfill") do
    attrs = %{
      id: row.id,
      legacy_id: row.legacy_id,
      login: row.login,
      email: row.email,
      full_name: row.full_name,
      legacy_state: row.legacy_state
    }

    UserProjection.project(attrs, context: %{ash_events_metadata: audit_metadata(row, path)})
  end

  # `legacy_*` cannot collide with the platform's own audit keys or the drain's `ledger_*` keys.
  defp audit_metadata(row, path) do
    %{
      "legacy_path" => path,
      "legacy_source_table" => AshStrangler.Info.relation(AshEnterprise.Legacy.User),
      "legacy_id" => row.legacy_id
    }
  end
end
