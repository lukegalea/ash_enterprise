defmodule Battery.Operations.Webhook do
  @moduledoc """
  What the battery registry's webhook contributes to the shared ingress
  (`AshOperations.Webhook.Provider`). A webhook is a NUDGE: it says "look at activation X".

    * `verify/2` checks `x-battery-signature`, the hex HMAC-SHA256 of
      `"<x-battery-timestamp>.<raw body>"` under any configured secret, and that the
      timestamp is within five minutes. No secret is `:not_configured`.
    * `dedup_key/2` is the `x-battery-delivery` header, stable across redeliveries.
    * `enqueue/2` records an id-shaped `activationId` as a `Delivery` and nothing else.
  """

  @behaviour AshOperations.Webhook.Provider

  alias AshOperations.Webhook.Signature
  alias Battery.Operations.Delivery

  require Ash.Query

  @tolerance_s 300
  @provider "battery-registry"
  @id_shape ~r/\A[A-Za-z0-9:_\-.]{1,128}\z/

  @impl AshOperations.Webhook.Provider
  def max_body_bytes, do: 2_048

  @impl AshOperations.Webhook.Provider
  def verify(conn, raw) do
    case secrets() do
      [] ->
        {:error, :not_configured}

      secrets ->
        with {:ok, timestamp} <- Signature.single_header(conn, "x-battery-timestamp"),
             {:ok, signature} <- Signature.single_header(conn, "x-battery-signature"),
             true <- Signature.fresh?(timestamp, System.os_time(:second), @tolerance_s),
             true <- Signature.valid_hex?(signature, secrets, [timestamp, ".", raw]) do
          :ok
        else
          _ -> {:error, :unauthorized}
        end
    end
  end

  @impl AshOperations.Webhook.Provider
  def dedup_key(conn, _payload) do
    case Signature.single_header(conn, "x-battery-delivery") do
      {:ok, key} when byte_size(key) <= 128 -> {:ok, key}
      _ -> {:error, :bad_request}
    end
  end

  @impl AshOperations.Webhook.Provider
  def enqueue(%{"activationId" => id}, key) when is_binary(id) do
    if id =~ @id_shape, do: record(id, key), else: {:reject, :bad_payload}
  end

  def enqueue(_payload, _key), do: {:reject, :bad_payload}

  @doc "The signature headers for `body`, signed now under `secret`. For tests and providers' senders."
  @spec sign(binary(), binary(), String.t()) :: [{String.t(), String.t()}]
  def sign(secret, body, delivery) do
    timestamp = Integer.to_string(System.os_time(:second))

    [
      {"x-battery-timestamp", timestamp},
      {"x-battery-signature", Signature.hmac_sha256_hex(secret, [timestamp, ".", body])},
      {"x-battery-delivery", delivery}
    ]
  end

  defp record(activation_id, key) do
    attrs = %{provider: @provider, dedup_key: key, activation_id: activation_id}

    case Delivery |> Ash.Changeset.for_create(:receive, attrs) |> Ash.create() do
      {:ok, _delivery} -> {:ok, :enqueued}
      {:error, _error} -> if recorded?(key), do: {:ok, :duplicate}, else: {:error, :insert_failed}
    end
  end

  defp recorded?(key) do
    Delivery
    |> Ash.Query.filter(provider == ^@provider and dedup_key == ^key)
    |> Ash.exists?()
  end

  defp secrets do
    :ash_enterprise_battery |> Application.get_env(__MODULE__, []) |> Keyword.get(:secrets, [])
  end
end
