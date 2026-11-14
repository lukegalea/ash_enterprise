defmodule AshEnterprise.Security.AuthenticationAudit do
  @moduledoc """
  Records admissions and refusals at the sign-in doors into the audit chain
  (`AshEnterprise.Security.AuthenticationEvent`). The doors call `admitted/2`,
  `refused/3` and `password_refused/2` and never build a changeset themselves:

    * the password door, from `AshEnterprise.Accounts.Preparations.SignInLockout`;
    * the password-reset and confirmation doors, from
      `AshEnterprise.Accounts.Changes.RecordSignIn`;
    * the API key door, from `AshEnterpriseWeb.Plugs.LoadFromBearer`.

  An admission that cannot be recorded returns `{:error, _}` and the door grants
  nothing: access with no evidence is not granted. A refusal that cannot be recorded is
  logged, without the identity, and still refused.

  Every write is made as the `sign_in` system actor, outside any tenant (see
  `AuthenticationEvent` for why the untenanted chain).
  """

  require Ash.Query
  require Logger

  alias AshAuthentication.Strategy.OAuth2
  alias AshEnterprise.Accounts.Preparations.MatchFederatedAccount
  alias AshEnterprise.Accounts.{User, UserIdentity}
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security

  @type door :: :password | :password_reset | :confirmation | :api_key | :oidc

  @doc "Records an admission of `user_id` at `door`."
  @spec admitted(door(), Ash.UUID.t()) :: :ok | {:error, term()}
  def admitted(door, user_id), do: write(%{door: door, outcome: :signed_in, user_id: user_id})

  @doc """
  Records a refusal at `door` for `reason`, with the user it resolved to if any.
  Always `:ok`: the refusal stands whether or not it was recorded.
  """
  @spec refused(door(), atom(), Ash.UUID.t() | nil) :: :ok
  def refused(door, reason, user_id \\ nil) do
    case write(%{door: door, outcome: :refused, reason: reason, user_id: user_id}) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.error(
          "authentication event not recorded (#{door}, #{inspect(reason)}): " <>
            Exception.message(error)
        )

        :ok
    end
  end

  @doc """
  Records a refused password sign-in for `identity` (the email typed), with its reason:
  `:locked` when the lockout held it, otherwise `:unknown_identity`, `:inactive` or
  `:wrong_password` by what the address belongs to. The address itself is not recorded.

  Known and unknown addresses cost the same here, one lookup and one write, so the
  recording does not tell a caller whether an address is registered.
  """
  @spec password_refused(term(), boolean()) :: :ok
  def password_refused(identity, locked?) do
    {reason, user_id} =
      case {locked?, find_user(identity)} do
        {true, user} -> {:locked, user && user.id}
        {false, nil} -> {:unknown_identity, nil}
        {false, %{lifecycle_status: :active} = user} -> {:wrong_password, user.id}
        {false, user} -> {:inactive, user.id}
      end

    refused(:password, reason, user_id)
  end

  @doc """
  Records a refused OIDC sign-in from what the identity provider asserted (`user_info`),
  with its reason, worked out the way the door decides:

    * `:unknown_identity`: no account has the asserted email, or none was asserted;
    * `:inactive`: the account is deactivated;
    * `:unconfirmed`: the account has not confirmed its address here;
    * `:identity_mismatch`: the provider subject is linked to another user, the account
      is linked to another subject, or the provider gave no stable subject;
    * `:unverified_email`: a first link the provider does not mark verified.

  Neither the email nor the subject is recorded, only the user the email belongs to.
  """
  @spec oidc_refused(map() | term()) :: :ok
  def oidc_refused(user_info) do
    email = MatchFederatedAccount.asserted_email(user_info)

    {reason, user_id} =
      case email && find_user(email) do
        nil -> {:unknown_identity, nil}
        %{lifecycle_status: status} = user when status != :active -> {:inactive, user.id}
        %{confirmed_at: nil} = user -> {:unconfirmed, user.id}
        user -> {link_refusal(user, user_info), user.id}
      end

    refused(:oidc, reason, user_id)
  end

  # The account was a candidate, so the strategy refused the link itself.
  defp link_refusal(user, user_info) do
    uid = if is_map(user_info), do: OAuth2.uid_from_user_info(user_info)

    cond do
      is_nil(uid) -> :identity_mismatch
      linked_elsewhere?(uid, user) -> :identity_mismatch
      email_verified?(user_info) -> :identity_mismatch
      true -> :unverified_email
    end
  end

  defp email_verified?(user_info) do
    Map.get(user_info, "email_verified", Map.get(user_info, :email_verified)) in [true, "true"]
  end

  defp linked_elsewhere?(uid, user) do
    UserIdentity
    |> Ash.Query.filter(strategy == "oidc" and (uid == ^uid or user_id == ^user.id))
    |> Ash.Query.select([:user_id, :uid])
    |> Ash.read(actor: SystemActor.sign_in())
    |> case do
      {:ok, identities} -> Enum.any?(identities, &(&1.user_id != user.id or &1.uid != uid))
      {:error, _} -> false
    end
  end

  defp find_user(identity) when is_binary(identity) or is_struct(identity, Ash.CiString) do
    User
    |> Ash.Query.filter(email == ^identity)
    |> Ash.Query.select([:id, :lifecycle_status, :confirmed_at])
    |> Ash.read_one(actor: SystemActor.sign_in())
    |> case do
      {:ok, user} -> user
      {:error, _} -> nil
    end
  end

  defp find_user(_identity), do: nil

  defp write(attrs) do
    attrs = Map.reject(attrs, fn {_key, value} -> is_nil(value) end)

    Faults.point(:authentication_event_record)

    case Security.record_authentication_event(attrs, actor: SystemActor.sign_in()) do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, error}
    end
  rescue
    error -> {:error, error}
  end
end
