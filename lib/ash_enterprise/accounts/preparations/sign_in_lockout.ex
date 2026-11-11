defmodule AshEnterprise.Accounts.Preparations.SignInLockout do
  @moduledoc """
  Puts the lockout around a password sign-in.

  Before the lookup, a locked or unreadable identity gets a query that matches
  nobody, which ends in the same "incorrect" answer as a wrong password. After
  it, a failure of any kind is counted and a success clears the count.

  A refused attempt is also handed to `AshEnterprise.Automation.Occurrences`, which
  records it for a known user and writes nothing for an unknown identity.

  Declare it before `AshAuthentication.Strategy.Password.SignInPreparation`.
  """
  use Ash.Resource.Preparation

  alias AshEnterprise.Accounts.Lockout
  alias AshEnterprise.Automation.Occurrences

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    identity = Ash.Query.get_argument(query, :email)

    query
    |> Ash.Query.before_action(fn query ->
      case Lockout.status_or_locked(identity) do
        :open ->
          Ash.Query.set_context(query, %{sign_in_locked?: false})

        {:locked, _} ->
          query |> Ash.Query.set_context(%{sign_in_locked?: true}) |> Ash.Query.filter(false)
      end
    end)
    |> Ash.Query.after_transaction(fn query, result ->
      settle(identity, result)
      announce(identity, query, result)
      result
    end)
  end

  # A refusal is handed to `Occurrences` and forgotten: it starts a task and returns,
  # for every refusal alike, so a known address costs the caller no more than an unknown
  # one and a failed write cannot touch the answer.
  defp announce(_identity, _query, {:ok, %{} = user}) when not is_list(user), do: :ok
  defp announce(_identity, _query, {:ok, [_user]}), do: :ok

  defp announce(identity, query, _failure),
    do: Occurrences.sign_in_refused(identity, Map.get(query.context, :sign_in_locked?, false))

  defp settle(identity, {:ok, %{} = user}) when not is_list(user), do: Lockout.clear(identity)
  defp settle(identity, {:ok, [_user]}), do: Lockout.clear(identity)
  defp settle(identity, _failure), do: Lockout.record_failure(identity)
end
