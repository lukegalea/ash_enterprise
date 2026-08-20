defmodule AshEnterprise.Legacy.Projection do
  @moduledoc """
  Turns a write in the legacy application into a write this application owns.

  An `Ash.Notifier` on `AshEnterprise.Legacy.User`. `AshStrangler.Listener` already re-reads a
  changed legacy row through Ash and dispatches a notification; this consumes that notification
  and upserts `AshEnterprise.Accounts.ProjectedUser` from it.

  The whole chain, end to end, because every link is opt-in and a break anywhere is quiet:

      INSERT INTO legacy.users ...              -- the legacy application, unmodified
        -> AFTER trigger                        (`notify? true` on the mapping)
        -> pg_notify, on commit only
        -> AshStrangler.Listener                (started in AshEnterprise.Application)
        -> re-read through the compatibility view, so the mapped values apply
        -> Ash.Notifier.Notification
        -> here
        -> ProjectedUser.project/2              -- an ordinary Ash action
        -> Ash.Notifier.PubSub, unremarkably
        -> the surface at /app/directory refreshes

  ## Why a notifier rather than a second listener

  The listener already does the hard part: it holds the `LISTEN` connection and re-reads the row
  *through Ash*, so the projected values are the mapped ones rather than raw legacy columns. A
  second listener would duplicate that and could disagree with it. A notifier is the seam that
  already exists for "something changed, react to it", and it means the projection sees exactly
  what the read model sees.

  ## It runs alongside the read model's notification, not instead of it

  Both notifiers are declared on `Legacy.User`, so a legacy write still refreshes
  `/app/legacy-users` *and* projects into `/app/directory`. That is deliberate: the two surfaces
  side by side are the demonstration, and a projection that replaced the read model would remove
  the thing it is being compared against.

  ## One entry point, and why that is not a style preference

  `project_row/1` is the only way a row gets projected. Both callers use it — this notifier for a
  live change, `mix ash_enterprise.legacy.project` for the backfill.

  They did not, at first, and the bug is instructive. The task rebuilt the attribute map itself
  and called the upsert directly, which meant it skipped the lifecycle transition: a legacy user
  in `suspended` or `passive` landed in `projected_users` carrying
  `lifecycle_status: :active`. The live path was correct and the backfill was not, so the value
  a row ended up with depended on whether anyone had edited it since the projector started —
  invisible in the code, obvious in one `SELECT`.

  ## Where failure is contained, and where it is not

  `project_row/1` **returns** `{:error, reason}` rather than swallowing it, because the backfill
  wants to report a refused row and a swallowed error gives it nothing to report.

  Containment is this notifier's job instead, and it is not optional here: a notifier that raises
  takes the listener's process with it, and the listener holds the only `LISTEN` connection — so
  one bad row would stop *all* reactivity, including the read model's, on every surface.

  That containment has a real cost, and it is worth naming rather than hiding: a row that fails
  to project is silently absent from `projected_users` until something re-runs the backfill.
  There is no retry and no dead-letter queue. The reconciliation job that would close the gap is
  step 6 of `docs/plans/ash-strangler-in-reference-app.md`, and this is not that.
  """

  use Ash.Notifier

  require Logger

  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Platform.SystemActor

  @doc """
  Projects one legacy row and aligns the projected row's lifecycle.

  Returns `:ok` or `{:error, reason}`. Does not rescue — see the moduledoc for which caller is
  responsible for containment and why it is not this function.
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

  @impl true
  def notify(%Ash.Notifier.Notification{} = notification) do
    # Only legacy-origin notifications. Today every notification on `Legacy.User` is one -- the
    # resource declares no write actions at `phase :read_from_legacy` -- but that stops being
    # true at `:dual_write`, and a projector that fed its own writes back would loop.
    case notification.metadata do
      %{ash_strangler: %{origin: :legacy}} -> contained(notification)
      _ -> :ok
    end

    :ok
  end

  defp contained(%{action: %{type: type}, data: data}) when type in [:create, :update] do
    case project_row(data) do
      :ok -> :ok
      {:error, reason} -> log_failure(data, reason)
    end
  rescue
    error -> log_failure(data, error)
  end

  # A hard DELETE in the legacy application. `acts_as_paranoid` means the common case is an
  # UPDATE of `deleted_at`, which arrives above and is carried by `archived_at` -- so this is the
  # rarer path where a row genuinely left the table.
  defp contained(%{action: %{type: :destroy}, data: data}) do
    case ProjectedUser.by_legacy_id(data.legacy_id, opts()) do
      {:ok, nil} -> :ok
      {:ok, record} -> Ash.destroy(record, opts())
      {:error, _} -> :ok
    end

    :ok
  rescue
    error -> log_failure(data, error)
  end

  defp contained(_notification), do: :ok

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

  defp log_failure(data, reason) do
    message =
      case reason do
        %{__exception__: true} = error -> Exception.message(error)
        other -> inspect(other)
      end

    Logger.error("""
    legacy projection failed for legacy_id #{inspect(Map.get(data, :legacy_id))}: #{message}

    The row is absent from projected_users until something re-runs
    mix ash_enterprise.legacy.project. There is no retry -- see AshEnterprise.Legacy.Projection.
    """)

    :ok
  end
end
