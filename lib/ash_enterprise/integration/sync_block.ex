defmodule AshEnterprise.Integration.SyncBlock do
  @moduledoc """
  Stops the scheduler polling an account that cannot sync until a person acts.

  A sync job that cancels is not retried, but the scheduler would enqueue a
  fresh step for the same account on its next tick, every 5 to 10 minutes,
  indefinitely: one provider or Nango request per account per tick for a
  revoked token, a deleted connection or an offboarded owner. So when a
  vertical's worker cancels for one of the reasons below, it marks the linked
  account `:block_sync` (`sync_blocked_reason`, `sync_blocked_at`), and
  `LinkedAccount.active_for_integration` skips it until someone runs
  `mix ash_enterprise.integration.sync --linked-account <id> --unblock` (or
  `LinkedAccount.unblock_sync`).

  | Reason | Means |
  |---|---|
  | `:unauthorized` | the provider token is revoked or expired: re-link |
  | `:connection_not_found` | Nango no longer has the connection: re-link |
  | `:scope_shredded` | the account's erasure scope is shredded: nothing may land under it again |
  | `:cross_scope_landing` | a record already exists under another scope: needs an operator |
  | `:user_inactive` | the account's owner is deactivated |

  Other cancellations (a missing grant, Nango not configured) are about the
  deployment, not the account, and are left to the next tick.
  """

  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.SystemActor

  @blocking [
    :unauthorized,
    :connection_not_found,
    :scope_shredded,
    :cross_scope_landing,
    :user_inactive
  ]

  @doc "The cancel reasons that block an account."
  def blocking_reasons, do: @blocking

  @doc """
  Pass a worker's result through, blocking `linked_account_id` first when the
  result is a cancellation for a blocking reason.
  """
  @spec after_result(term(), Ash.UUID.t()) :: term()
  def after_result({:cancel, reason} = result, linked_account_id) do
    case blocking(reason) do
      nil -> :ok
      reason -> block(linked_account_id, reason)
    end

    result
  end

  def after_result(result, _linked_account_id), do: result

  @doc "The blocking reason a cancel reason names, or nil."
  @spec blocking(term()) :: atom() | nil
  def blocking(reason) when reason in @blocking, do: reason

  # The calendar worker reports a refused landing as "landing_refused: <detail>".
  def blocking("landing_refused: " <> detail),
    do: Enum.find(@blocking, &(Atom.to_string(&1) == detail))

  def blocking(_reason), do: nil

  # A trusted step of the sync machinery, attributed to the `oban` system
  # actor: the account was already resolved as its owner by the cancelled
  # step, and an unlinked account is simply gone.
  defp block(linked_account_id, reason) do
    with {:ok, %LinkedAccount{} = account} <-
           Ash.get(LinkedAccount, linked_account_id,
             authorize?: false,
             not_found_error?: false
           ),
         nil <- account.sync_blocked_at do
      LinkedAccount.block_sync(account, Atom.to_string(reason),
        actor: SystemActor.oban(),
        tenant: account.organization_id
      )
    end

    :ok
  end
end
