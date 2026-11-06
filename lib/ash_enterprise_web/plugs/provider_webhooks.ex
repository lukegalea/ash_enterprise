defmodule AshEnterpriseWeb.Plugs.ProviderWebhooks do
  @moduledoc """
  The provider webhook ingress (`AshOperations.Webhook.Ingress`), mounted in the endpoint
  ahead of `Plug.Parsers` and matching only `POST /webhooks/:provider`.

  A signature covers the exact bytes the provider sent, and `Plug.Parsers` consumes a JSON
  body before the router sees it, so the ingress reads the raw bytes itself and has to run
  first. Every other request passes through untouched: the raw-body read is scoped to this one
  route, with no global `body_reader` caching every request's body, and sessions and CSRF do
  not apply because the route is ahead of the router. `mix phx.routes` does not list it; the
  router carries a comment that points here.

  | Provider segment | Handled by |
  |---|---|
  | `credential-registry` | `AshEnterprise.Credentialing.RegistryWebhook` |

  Deliveries are rate limited per provider and remote address (429, empty body) before the
  ingress reads a byte. Responses are the ingress's own: empty bodies, and the statuses in
  its moduledoc.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshOperations.Webhook.Ingress

  @providers %{"credential-registry" => AshEnterprise.Credentialing.RegistryWebhook}

  # Per provider and address: generous for a provider's retries, tight enough that an
  # unauthenticated sender cannot make the ingress read bodies without bound.
  @window_ms 60_000
  @limit 300

  @impl Plug
  def init(opts), do: Keyword.put_new(opts, :providers, @providers)

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["webhooks", provider]} = conn, opts) do
    case AshEnterprise.Hammer.hit("webhook:#{provider}:#{address(conn)}", @window_ms, @limit) do
      {:allow, _count} ->
        conn = %{conn | path_params: Map.put(conn.path_params, "provider", provider)}
        Ingress.call(conn, Ingress.init(providers: Keyword.fetch!(opts, :providers)))

      {:deny, _retry_after_ms} ->
        conn |> send_resp(429, "") |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp address(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()
end
