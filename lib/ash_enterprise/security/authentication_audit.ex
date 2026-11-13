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

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security

  @type door :: :password | :password_reset | :confirmation | :api_key

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

  defp find_user(identity) when is_binary(identity) or is_struct(identity, Ash.CiString) do
    User
    |> Ash.Query.filter(email == ^identity)
    |> Ash.Query.select([:id, :lifecycle_status])
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
