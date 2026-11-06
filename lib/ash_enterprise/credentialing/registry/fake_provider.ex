defmodule AshEnterprise.Credentialing.Registry.FakeProvider do
  @moduledoc """
  The in-process fake of the credential registry's HTTP API: a `Plug` that serves the
  synthetic spec (`priv/vendor/credential_registry/openapi.json`) over the ETS state in
  `AshEnterprise.Credentialing.Registry`.

  It is what `RegistryApi.Transport` talks to when no `CREDENTIAL_REGISTRY_URL` is set, so
  dev, demo and test run offline and the whole path (generated action, transport, retry
  table, error classification) is exercised rather than stubbed above it. It is not a
  security boundary: it checks no credential.

    * `POST /v1/activations` records an activation (201). Every call is a new activation.
    * `GET /v1/activations?subjectReference=` lists a credential's activations (200).
    * `GET /v1/activations/{id}` answers one (200), or 404.
    * When the registry's table is down every route answers 503 with the error envelope
      `{"code": "unavailable", "requestId": ...}`.

  A credential reference is `"<organization_id>:<credential_id>"`
  (`AshEnterprise.Credentialing.RegistryApi.reference/2`); the fake keys its memory by the
  credential id inside it.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshEnterprise.Credentialing.Registry
  alias AshEnterprise.Credentialing.RegistryApi

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Registry.available?() do
      conn = fetch_query_params(conn)
      route(conn, conn.method, conn.path_info)
    else
      json(conn, 503, %{"code" => "unavailable", "requestId" => request_id()})
    end
  end

  defp route(conn, "POST", ["v1", "activations"]) do
    {:ok, body, conn} = read_body(conn)

    with {:ok, %{"subjectReference" => reference}} <- Jason.decode(body),
         {:ok, {_org, credential_id}} <- RegistryApi.parse_reference(reference),
         {:ok, id} <- Registry.activate(credential_id, reference) do
      json(conn, 201, activation(id, reference))
    else
      _ -> json(conn, 400, %{"code" => "bad_request", "requestId" => request_id()})
    end
  end

  defp route(conn, "GET", ["v1", "activations"]) do
    reference = conn.query_params["subjectReference"]

    entries =
      with {:ok, {_org, credential_id}} <- RegistryApi.parse_reference(reference) do
        Registry.entries(credential_id)
      else
        _ -> []
      end

    json(conn, 200, %{
      "data" => Enum.map(entries, &activation(&1.id, &1.credential_reference || reference))
    })
  end

  defp route(conn, "GET", ["v1", "activations", id]) do
    case Registry.find(URI.decode(id)) do
      {:ok, entry} -> json(conn, 200, activation(entry.id, entry.credential_reference))
      :error -> json(conn, 404, %{"code" => "not_found", "requestId" => request_id()})
    end
  end

  defp route(conn, _method, _path),
    do: json(conn, 404, %{"code" => "not_found", "requestId" => request_id()})

  # An activation made without a reference (the stub called directly) is listed under the
  # reference it was asked about.
  defp activation(id, reference),
    do: %{"id" => id, "subjectReference" => reference, "status" => "active"}

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp request_id, do: "fake-" <> Integer.to_string(System.unique_integer([:positive]))
end
