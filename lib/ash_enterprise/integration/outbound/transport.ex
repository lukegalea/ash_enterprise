defmodule AshEnterprise.Integration.Outbound.Transport do
  @moduledoc """
  The only HTTP client for outbound webhooks (Iron Law #20), over `AshOperations.Http`.

  `config/1` chooses the destination per call, from `meta.call`: the endpoint named by the
  `endpoint_id` context param, read in the call's own tenant. Its URL goes through the egress
  guard (`AshEnterprise.Integration.Outbound.Egress.vet/2`), and the request goes to the
  address that was vetted, with the name kept for `Host`, SNI and certificate verification
  (`connect_options: [hostname: name]`), so DNS cannot be rebound under it. Redirects are not
  followed. The operation's `/` path is replaced by the registered URL's own path and query.

  One attempt per call (`max_attempts: 1`): the retry schedule is the delivery's
  (`AshEnterprise.Integration.Outbound.Changes.Deliver`), measured in minutes and hours,
  not a worker sleeping.

  `sign/3` implements Standard Webhooks v1 over the exact bytes sent:

      webhook-id:        <the audit event id>
      webhook-timestamp: <unix seconds>
      webhook-signature: v1,<base64 HMAC-SHA256 of "id.timestamp.body", keyed by the
                         base64-decoded part of the whsec_ secret>

  Refusals, before anything is sent: an unknown endpoint (`"endpoint_unknown"`), a shredded
  secret (`"secret_shredded"`), and every egress refusal, with the guard's code. An
  unresolvable host fails as `:transport` (`"egress_unresolvable"`), so it is retried.
  """

  use AshOperations.Http

  alias AshEnterprise.Erasure.Keyring
  alias AshEnterprise.Integration.Outbound.{Egress, Endpoint}

  @impl AshOperations.Http
  def config(%{call: %{tenant: tenant, context_params: %{endpoint_id: id}}})
      when not is_nil(tenant) do
    settings = Application.get_env(:ash_enterprise, __MODULE__, [])

    with {:ok, endpoint} <- endpoint(tenant, id),
         {:ok, secret} <- secret(endpoint),
         {:ok, vetted} <- vet(endpoint.url) do
      {:ok,
       %{
         base_url: vetted.base_url,
         headers: [{"content-type", "application/cloudevents+json"}],
         redirect: false,
         max_attempts: 1,
         secret: secret,
         req_options:
           [url: vetted.path, connect_options: [hostname: vetted.hostname]] ++
             Keyword.get(settings, :req_options, [])
       }}
    end
  end

  def config(_meta), do: {:error, {:disclosure_refused, "no_tenant"}}

  @impl AshOperations.Http
  def sign(body, %{call: %{context_params: %{message_id: id}}}, %{secret: secret}) do
    timestamp = Integer.to_string(System.os_time(:second))

    [
      {"webhook-id", id},
      {"webhook-timestamp", timestamp},
      {"webhook-signature", "v1," <> signature(secret, id, timestamp, body || "")}
    ]
  end

  @doc """
  The Standard Webhooks v1 signature of one message: base64 HMAC-SHA256 of
  `"<id>.<timestamp>.<body>"`, keyed by the base64-decoded part of a `whsec_` secret.
  """
  @spec signature(String.t(), String.t(), String.t(), binary()) :: String.t()
  def signature("whsec_" <> key, id, timestamp, body) do
    :crypto.mac(:hmac, :sha256, Base.decode64!(key), "#{id}.#{timestamp}.#{body}")
    |> Base.encode64()
  end

  defp endpoint(tenant, id) do
    case Ash.get(Endpoint, id, tenant: tenant, authorize?: false) do
      {:ok, %Endpoint{} = endpoint} -> {:ok, endpoint}
      {:error, _} -> {:error, {:disclosure_refused, "endpoint_unknown"}}
    end
  end

  defp secret(%Endpoint{sealed_secret: sealed}) do
    case Keyring.open!(Base.decode64!(sealed)) do
      {:ok, secret} -> {:ok, secret}
      {:shredded, _} -> {:error, {:not_configured, "secret_shredded"}}
    end
  end

  defp vet(url) do
    case Egress.vet(url) do
      {:ok, vetted} -> {:ok, vetted}
      {:error, "egress_unresolvable" = code} -> {:error, {:transport, code}}
      {:error, code} -> {:error, {:disclosure_refused, code}}
    end
  end
end
