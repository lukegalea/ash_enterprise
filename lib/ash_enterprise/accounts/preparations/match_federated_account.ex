defmodule AshEnterprise.Accounts.Preparations.MatchFederatedAccount do
  @moduledoc """
  The account an OIDC sign-in may reach: the one user whose email equals the email the
  identity provider asserted (`user_info["email"]`), and only if that user has confirmed
  the address here. ADR 0071.

  Nothing else is a candidate. A provider that asserts no email matches nobody, and an
  unconfirmed account is not matched even when the address is right: its owner has not
  proved the address to this deployment, so a provider's word alone does not open it.
  The comparison is the column's own (`email` is a case-insensitive string).

  This only chooses the candidate. `AshAuthentication.Strategy.OAuth2.SignInPreparation`
  then decides whether the provider's subject may sign in as it: an existing link to
  that user, or a first link only when the provider marks the email verified.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case asserted_email(Ash.Query.get_argument(query, :user_info)) do
      nil -> Ash.Query.filter(query, false)
      email -> Ash.Query.filter(query, email == ^email and not is_nil(confirmed_at))
    end
  end

  @doc "The email `user_info` asserts, trimmed, or nil when it asserts none."
  @spec asserted_email(term()) :: String.t() | nil
  def asserted_email(%{} = user_info) do
    case Map.get(user_info, "email", Map.get(user_info, :email)) do
      email when is_binary(email) ->
        case String.trim(email) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  def asserted_email(_user_info), do: nil
end
