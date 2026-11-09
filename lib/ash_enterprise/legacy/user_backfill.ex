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

  `project_row/1` is the only way the backfill projects a row. It aligns `lifecycle_status`
  through the platform's own state machine: a legacy user in `suspended` or `passive` must not
  land in `projected_users` carrying `lifecycle_status: :active`. An earlier version of the task
  rebuilt the attribute map itself and called the upsert directly, which skipped the transition,
  so the value a row ended up with depended on which path had written it last.

  `project_row/1` **returns** `{:error, reason}` rather than swallowing it, because the backfill
  wants to report a refused row and a swallowed error gives it nothing to report.
  """

  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Platform.SystemActor

  @doc """
  Projects one legacy row and aligns the projected row's lifecycle.

  Returns `:ok` or `{:error, reason}`. Does not rescue: the caller reports a refused row.
  """
  @spec project_row(struct()) :: :ok | {:error, term()}
  def project_row(row) do
    attrs = %{
      id: row.id,
      legacy_id: row.legacy_id,
      login: row.login,
      email: row.email,
      full_name: row.full_name,
      legacy_state: row.legacy_state
    }

    with {:ok, projected} <- ProjectedUser.project(attrs, opts()) do
      align_lifecycle(projected, row.legacy_state)
    end
  end

  defp align_lifecycle(%{lifecycle_status: :active} = record, legacy_state)
       when legacy_state not in ["active", nil],
       do: transition(record, :deactivate)

  defp align_lifecycle(%{lifecycle_status: :inactive} = record, "active"),
    do: transition(record, :activate)

  defp align_lifecycle(_record, _legacy_state), do: :ok

  defp transition(record, action) do
    record
    |> Ash.Changeset.for_update(action, %{}, opts())
    |> Ash.update()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The actor is `SystemActor.projection/0` rather than a person, and the tenant is the legacy
  # estate's organization. See `ProjectedUser`'s moduledoc for why borrowing a human name here
  # would be a lie.
  defp opts do
    [actor: SystemActor.projection(), tenant: Estate.organization_id(), authorize?: false]
  end
end
