defmodule Battery.Operations.Router do
  @moduledoc """
  The battery's webhook mount: `POST /webhooks/:provider` to the shared ingress. There is
  NO `Plug.Parsers` before it, so the ingress reads the exact bytes the provider signed.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post("/webhooks/:provider",
    to: AshOperations.Webhook.Ingress,
    init_opts: [
      providers: %{"battery-registry" => Battery.Operations.Webhook},
      telemetry_prefix: [:battery_operations, :webhook]
    ]
  )

  match _ do
    send_resp(conn, 404, "")
  end
end
