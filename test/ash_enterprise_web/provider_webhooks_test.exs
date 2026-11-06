defmodule AshEnterpriseWeb.ProviderWebhooksTest do
  @moduledoc """
  The registry's webhook route, as wiring: mounted in the endpoint ahead of `Plug.Parsers`,
  signature over the exact bytes, one row per delivery. The statuses of the ingress itself,
  the signature helpers and the dedup contract are the `ash_operations` suite's; this checks
  the host's mount order, secret resolution and the delivery it records.
  """

  # async: false. It swaps the webhook secrets in the application env, which is node-global.
  use AshEnterpriseWeb.ConnCase, async: false

  alias AshEnterprise.Credentialing.RegistryWebhook
  alias AshOperations.Webhook.Signature

  @secret "synthetic-webhook-secret"

  setup do
    previous = Application.get_env(:ash_enterprise, RegistryWebhook)
    Application.put_env(:ash_enterprise, RegistryWebhook, secrets: [@secret])

    on_exit(fn ->
      AshEnterprise.Test.RegistryActivation.restore_env(RegistryWebhook, previous)
    end)

    %{delivery_id: "delivery-#{System.unique_integer([:positive])}"}
  end

  defp deliver(conn, body, delivery_id, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, Integer.to_string(System.os_time(:second)))
    signed = Keyword.get(opts, :signed, body)
    secret = Keyword.get(opts, :secret, @secret)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-registry-timestamp", timestamp)
    |> put_req_header(
      "x-registry-signature",
      Signature.hmac_sha256_hex(secret, [timestamp, ".", signed])
    )
    |> put_req_header("x-registry-delivery", delivery_id)
    |> post("/webhooks/#{Keyword.get(opts, :provider, "credential-registry")}", body)
  end

  defp deliveries(delivery_id) do
    Enum.filter(
      AshEnterprise.Integration.list_provider_deliveries!(authorize?: false),
      &(&1.dedup_key == delivery_id)
    )
  end

  test "a signed delivery is 204 and recorded once, and its redelivery records nothing", %{
    conn: conn,
    delivery_id: id
  } do
    body = Jason.encode!(%{"activationId" => "act-1", "ignored" => "values"})

    assert conn |> deliver(body, id) |> response(204) == ""

    assert [%{subject_id: "act-1", state: :received, provider: "credential-registry"}] =
             deliveries(id)

    assert build_conn() |> deliver(body, id) |> response(204) == ""
    assert [_one] = deliveries(id)
  end

  test "the signature covers the exact bytes Plug.Parsers never saw", %{
    conn: conn,
    delivery_id: id
  } do
    # Whitespace a JSON re-encoding would drop: only the raw bytes verify.
    raw = ~s({  "activationId" :   "act-2"\n})

    assert conn |> deliver(raw, id) |> response(204)
    assert [%{subject_id: "act-2"}] = deliveries(id)

    other = "other-#{id}"
    compact = Jason.encode!(%{"activationId" => "act-3"})

    assert build_conn() |> deliver(raw, other, signed: compact) |> response(401)
    assert deliveries(other) == []
  end

  test "a bad or stale signature is 401", %{conn: conn, delivery_id: id} do
    body = Jason.encode!(%{"activationId" => "act-4"})

    assert conn |> deliver(body, id, secret: "not-the-secret") |> response(401)

    stale = Integer.to_string(System.os_time(:second) - 3_600)
    assert build_conn() |> deliver(body, id, timestamp: stale) |> response(401)
    assert deliveries(id) == []
  end

  test "no configured secret is 503", %{conn: conn, delivery_id: id} do
    Application.put_env(:ash_enterprise, RegistryWebhook, secrets: [])
    body = Jason.encode!(%{"activationId" => "act-5"})

    assert conn |> deliver(body, id) |> response(503)
    assert deliveries(id) == []
  end

  test "an unknown provider is 404", %{conn: conn, delivery_id: id} do
    body = Jason.encode!(%{"activationId" => "act-6"})
    assert conn |> deliver(body, id, provider: "someone-else") |> response(404)
  end

  test "an oversized body is 413", %{conn: conn, delivery_id: id} do
    body = Jason.encode!(%{"activationId" => "act-7", "padding" => String.duplicate("x", 20_000)})

    assert conn |> deliver(body, id) |> response(413)
    assert deliveries(id) == []
  end

  test "a payload that names no activation id is rejected, never recorded", %{
    conn: conn,
    delivery_id: id
  } do
    for payload <- [%{}, %{"activationId" => 7}, %{"activationId" => "has space"}] do
      assert build_conn() |> deliver(Jason.encode!(payload), id) |> response(400)
    end

    assert deliveries(id) == []
  end

  test "other JSON routes still parse", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/gql", Jason.encode!(%{query: "{ __schema { queryType { name } } }"}))

    assert %{"data" => %{"__schema" => %{"queryType" => %{"name" => _}}}} =
             json_response(conn, 200)
  end
end
