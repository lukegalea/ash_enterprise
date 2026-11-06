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

  Failed verifications (400 and 401) are counted per provider and remote address, and past
  the limit they answer 429 instead. A verified delivery is never limited: behind a TLS
  proxy every sender shares the proxy's address, so limiting deliveries by address would let
  an unsigned flood starve the provider's real ones. A segment that names no provider is a
  404 and creates no bucket. Responses are otherwise the ingress's own: empty bodies, and the
  statuses in its moduledoc.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshOperations.Webhook.Ingress

  @providers %{"credential-registry" => AshEnterprise.Credentialing.RegistryWebhook}

  # Failed verifications per provider and address.
  @window_ms 60_000
  @limit 300

  @impl Plug
  def init(opts), do: Keyword.put_new(opts, :providers, @providers)

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["webhooks", provider]} = conn, opts) do
    providers = Keyword.fetch!(opts, :providers)
    conn = %{conn | path_params: Map.put(conn.path_params, "provider", provider)}

    conn =
      if Map.has_key?(providers, provider),
        do: register_before_send(conn, &limit_failures(&1, provider)),
        else: conn

    Ingress.call(conn, Ingress.init(providers: providers))
  end

  def call(conn, _opts), do: conn

  defp limit_failures(%Plug.Conn{status: status} = conn, provider) when status in [400, 401] do
    case AshEnterprise.Hammer.hit("webhook:#{provider}:#{address(conn)}", @window_ms, @limit) do
      {:allow, _count} -> conn
      {:deny, _retry_after_ms} -> %{conn | status: 429, resp_body: ""}
    end
  end

  defp limit_failures(conn, _provider), do: conn

  defp address(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()
end
