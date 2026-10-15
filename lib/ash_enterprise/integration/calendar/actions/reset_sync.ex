defmodule AshEnterprise.Integration.Calendar.Actions.ResetSync do
  @moduledoc """
  `Sync.reset_sync`: the explicit sync-reset for one of the actor's own
  accounts. Returns `%{linked_account_id: id, reset: count}`.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Integration.Calendar.Step

  @impl true
  def run(input, _opts, context) do
    with {:ok, account} <-
           Step.resolve_account(context.actor, Map.get(input.arguments, :linked_account_id)),
         {:ok, count} <- Step.reset(context.actor, account.id) do
      {:ok, %{linked_account_id: account.id, reset: count}}
    end
  end
end
