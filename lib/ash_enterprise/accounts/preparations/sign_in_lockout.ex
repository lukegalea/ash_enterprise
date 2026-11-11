defmodule AshEnterprise.Accounts.Preparations.SignInLockout do
  @moduledoc """
  Puts the lockout around a password sign-in.

  Before the lookup, a locked or unreadable identity gets a query that matches
  nobody, which ends in the same "incorrect" answer as a wrong password. After
  it, a failure of any kind is counted and a success clears the count.

  Declare it before `AshAuthentication.Strategy.Password.SignInPreparation`.
  """
  use Ash.Resource.Preparation

  alias AshEnterprise.Accounts.Lockout

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    identity = Ash.Query.get_argument(query, :email)

    query
    |> Ash.Query.before_action(fn query ->
      case Lockout.status_or_locked(identity) do
        :open -> query
        {:locked, _} -> Ash.Query.filter(query, false)
      end
    end)
    |> Ash.Query.after_transaction(fn _query, result ->
      settle(identity, result)
      result
    end)
  end

  defp settle(identity, {:ok, %{} = user}) when not is_list(user), do: Lockout.clear(identity)
  defp settle(identity, {:ok, [_user]}), do: Lockout.clear(identity)
  defp settle(identity, _failure), do: Lockout.record_failure(identity)
end
