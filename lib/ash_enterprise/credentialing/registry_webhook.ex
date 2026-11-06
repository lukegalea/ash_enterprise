defmodule AshEnterprise.Credentialing.RegistryWebhook do
  @moduledoc """
  What the credential registry's webhook contributes to the shared ingress
  (`AshOperations.Webhook.Provider`, mounted by `AshEnterpriseWeb.Plugs.ProviderWebhooks`).

  A webhook is a **nudge**: it says "look at activation X". Nothing here acts on a payload
  value, takes a tenant or an actor from it, or follows a URL in it. The delivery records the
  activation id and nothing else; the follow-up
  (`AshEnterprise.Integration.Operations.Delivery`) reads the registry by that id through a
  declared operation and only makes a reconcile run sooner.

    * `verify/2` checks `x-registry-signature`, the hex HMAC-SHA256 of
      `"<x-registry-timestamp>.<raw body>"`, and that the timestamp is within five minutes.
      The secrets are `CREDENTIAL_REGISTRY_WEBHOOK_SECRETS` (comma-separated, so a secret can
      be rotated with both live); none configured is `:not_configured` (503).
    * `dedup_key/2` is the `x-registry-delivery` header, which is stable across redeliveries.
    * `enqueue/2` accepts `payload["activationId"]` as an id-shaped string and nothing else.
  """

  @behaviour AshOperations.Webhook.Provider

  alias AshEnterprise.Integration.Operations.Delivery
  alias AshEnterprise.Platform.SystemActor
  alias AshOperations.Webhook.Signature

  @tolerance_s 300
  @provider "credential-registry"
  @id_shape ~r/\A[A-Za-z0-9:_\-.]{1,128}\z/

  @impl AshOperations.Webhook.Provider
  def max_body_bytes, do: 16_384

  @impl AshOperations.Webhook.Provider
  def verify(conn, raw) do
    case secrets() do
      [] ->
        {:error, :not_configured}

      secrets ->
        with {:ok, timestamp} <- Signature.single_header(conn, "x-registry-timestamp"),
             {:ok, signature} <- Signature.single_header(conn, "x-registry-signature"),
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
    case Signature.single_header(conn, "x-registry-delivery") do
      {:ok, key} when byte_size(key) <= 128 -> {:ok, key}
      _ -> {:error, :bad_request}
    end
  end

  @impl AshOperations.Webhook.Provider
  def enqueue(%{"activationId" => id}, key) when is_binary(id) do
    if id =~ @id_shape, do: record(id, key), else: {:reject, :bad_payload}
  end

  def enqueue(_payload, _key), do: {:reject, :bad_payload}

  defp record(activation_id, key) do
    attrs = %{provider: @provider, dedup_key: key, subject_id: activation_id}

    case AshEnterprise.Integration.receive_provider_delivery(attrs, actor: SystemActor.oban()) do
      {:ok, _delivery} -> {:ok, :enqueued}
      {:error, error} -> if duplicate?(key), do: {:ok, :duplicate}, else: failed(error)
    end
  end

  defp duplicate?(key), do: Delivery.recorded?(@provider, key)

  # Never log or return the error: it may carry the payload's values.
  defp failed(_error), do: {:error, :insert_failed}

  defp secrets,
    do: :ash_enterprise |> Application.get_env(__MODULE__, []) |> Keyword.get(:secrets, [])
end
