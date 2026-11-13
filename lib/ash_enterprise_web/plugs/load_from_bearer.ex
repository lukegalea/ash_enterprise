defmodule AshEnterpriseWeb.Plugs.LoadFromBearer do
  @moduledoc """
  Authenticates a `Authorization: Bearer <credential>` header.

  Two credentials travel in that header and this plug tells them apart by what
  they look like:

    * a key issued by `AshEnterprise.Accounts.ApiKey` (it starts with `aek_`) is
      checked by the API key strategy. A key that does not check out -- unknown,
      expired, revoked, malformed or owned by a deactivated user -- is answered
      with 401 and the request stops; it is never passed on as anonymous. Each such
      refusal is recorded in the audit chain (`AshEnterprise.Security.AuthenticationAudit`,
      door `:api_key`); a request a key admits is not, or the chain would hold a row per
      API call.
    * anything else is a session token, handled by
      `AshAuthentication.Plug.Helpers.retrieve_from_bearer/3`, which authenticates
      nobody when the token is unusable and leaves the policies to refuse.

  No header at all is an anonymous request, as before.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshEnterprise.Security.AuthenticationAudit

  @key_prefix "aek_"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case bearer(conn) do
      @key_prefix <> _ ->
        api_key_plug().call(conn, api_key_config())

      _ ->
        AshAuthentication.Plug.Helpers.retrieve_from_bearer(conn, :ash_enterprise, opts)
    end
  end

  defp bearer(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.find_value(fn
      "Bearer " <> credential -> credential
      _ -> nil
    end)
  end

  defp api_key_plug, do: AshAuthentication.Strategy.ApiKey.Plug

  defp api_key_config do
    api_key_plug().init(
      resource: AshEnterprise.Accounts.User,
      required?: false,
      on_error: &__MODULE__.refuse/2
    )
  end

  # The API key strategy's error callback: records the refusal, then answers it the way the
  # strategy does (401, halted).
  @doc false
  def refuse(conn, error) do
    AuthenticationAudit.refused(:api_key, :api_key_rejected)
    api_key_plug().on_error(conn, error)
  end
end
