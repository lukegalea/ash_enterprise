defmodule AshEnterpriseWeb.Plugs.RequireActor do
  @moduledoc """
  Halts the request with 401 when no actor was resolved.

  Ash policies fail closed, so an actorless request would already read nothing
  and write nothing. This plug exists anyway, for the MCP surface specifically,
  because "fails closed" and "rejects the connection" are different guarantees
  and only the second is obvious to whoever wires up a client.

  An MCP endpoint that accepts anonymous connections and quietly returns empty
  results looks like a *working* integration with no data. The reasonable next
  step for whoever is debugging that is to relax authorization until data
  appears — which is how an unauthenticated API over the whole domain gets
  shipped, one plausible step at a time.

  Failing loudly at the door removes that path.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        401,
        Jason.encode!(%{
          error: "unauthenticated",
          message:
            "This endpoint requires an actor. Send an API key as `Authorization: Bearer <key>`."
        })
      )
      |> Plug.Conn.halt()
    end
  end
end
