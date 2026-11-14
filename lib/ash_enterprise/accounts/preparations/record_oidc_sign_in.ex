defmodule AshEnterprise.Accounts.Preparations.RecordOidcSignIn do
  @moduledoc """
  Records every OIDC sign-in at the `:oidc` door of the audit chain
  (`AshEnterprise.Security.AuthenticationAudit`): an admission with the user, or a
  refusal with its reason. ADR 0071.

  An admission the chain cannot hold is turned into a refusal, so no token leaves
  without the evidence of it, as at the password door. A refusal that cannot be
  recorded is still a refusal.

  Declare it first among the sign-in action's preparations: its hook runs after the
  transaction, when `AshAuthentication.Strategy.OAuth2.SignInPreparation` has matched
  the subject and issued the token, or refused.
  """

  use Ash.Resource.Preparation

  alias AshAuthentication.Errors.AuthenticationFailed
  alias AshEnterprise.Security.AuthenticationAudit

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_transaction(query, fn query, result -> audit(query, result) end)
  end

  defp audit(query, {:ok, [user]} = result) do
    case AuthenticationAudit.admitted(:oidc, user.id) do
      :ok ->
        result

      {:error, _error} ->
        {:error,
         AuthenticationFailed.exception(
           query: query,
           caused_by: %{
             module: __MODULE__,
             action: query.action,
             resource: query.resource,
             message: "The sign-in could not be recorded"
           }
         )}
    end
  end

  defp audit(query, result) do
    query |> Ash.Query.get_argument(:user_info) |> AuthenticationAudit.oidc_refused()
    result
  end
end
