defmodule AshEnterprise.Automation.AlertWebhook do
  @moduledoc """
  The inbound alert webhook: an alert raised by SigNoz or GlitchTip, verified and recorded
  as an `AshEnterprise.Automation.Occurrence` (`alert.firing` or `alert.resolved`) in one
  organization, where a recipe can match it.

  Mounted on the shared provider ingress (`AshOperations.Webhook.Ingress`, through
  `AshEnterpriseWeb.Plugs.ProviderWebhooks`) as two providers that differ only in how they
  read a payload:

  | Route | Provider |
  |---|---|
  | `POST /webhooks/alerts-signoz` | `AshEnterprise.Automation.AlertWebhook.Signoz` (Alertmanager-shaped body) |
  | `POST /webhooks/alerts-glitchtip` | `AshEnterprise.Automation.AlertWebhook.Glitchtip` (its Slack-shaped body) |

  ## Keys, and the one tenant a key reaches

  A key is an id, a secret and the organization it records into:

      config :ash_enterprise, AshEnterprise.Automation.AlertWebhook,
        keys: [%{id: "ops", organization_id: "<uuid>", secret: "<random>"}]

  `ALERT_WEBHOOK_KEYS` sets them in a deployment (`config/runtime.exs`). A request names its
  key in `x-alert-key` and signs with it: `x-alert-signature` is the hex HMAC-SHA256 of
  `"<x-alert-timestamp>.<raw body>"` under that key's secret, and the timestamp (Unix
  seconds) must be within five minutes. Only the named key's secret is tried, so a caller
  holding one key cannot sign for another, and the organization is the key's: nothing in a
  payload, a header or the path chooses it. No key configured answers 503; an unknown key, a
  missing header, a wrong or stale signature 401, and nothing is recorded.

  Neither SigNoz nor GlitchTip signs a webhook body, so they deliver through something that
  holds the key and adds the three headers (a relay at the edge, or the collector a host
  already runs). Both tools' webhook channels can point at that relay unchanged.

  ## Replays

  A replayed request within the five minutes is the same alerts again: each occurrence's
  identity is its `source` and `event_id`, so a replay records nothing new (204). Outside
  the five minutes the signature is stale (401). An alert's `event_id` is the provider's own
  id for it: for SigNoz the fingerprint, start time and status; for GlitchTip, which gives an
  alert no id, the issue and the signed timestamp.

  ## Facts, not payloads

  The occurrence keeps a few short labels (`alertname`, `severity`, `category`, `rule_id`)
  and nothing else from the body: no annotation, description, URL or value, since a payload
  is the sender's text. Labels are cut to 120 characters. At most 20 alerts are read from
  one request. Nothing here logs; the ingress reports one telemetry event per request.
  """

  alias AshEnterprise.Automation.Occurrences
  alias AshOperations.Webhook.Signature

  @tolerance_s 300
  @key_id ~r/\A[a-z0-9][a-z0-9_-]{0,39}\z/
  @timestamp ~r/\A[0-9]{1,12}\z/

  @typedoc "An alert read from a payload: an occurrence's attributes without its source."
  @type alert :: %{
          required(:event_id) => String.t(),
          required(:type) => String.t(),
          required(:subject) => String.t() | nil,
          required(:data) => map(),
          optional(:time) => DateTime.t()
        }

  @doc "The keys configured: `[%{id:, organization_id:, secret:}]`, malformed entries dropped."
  @spec keys() :: [%{id: String.t(), organization_id: String.t(), secret: String.t()}]
  def keys do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:keys, [])
    |> Enum.flat_map(&key/1)
  end

  defp key(%{id: id, organization_id: org, secret: secret})
       when is_binary(id) and is_binary(org) and is_binary(secret) and secret != "" do
    if Regex.match?(@key_id, id), do: [%{id: id, organization_id: org, secret: secret}], else: []
  end

  defp key(entry) when is_list(entry), do: entry |> Map.new() |> key()
  defp key(_entry), do: []

  @doc "Checks the request's key, timestamp and signature over `raw`. See the moduledoc."
  @spec verify(Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized | :not_configured}
  def verify(conn, raw) do
    case keys() do
      [] ->
        {:error, :not_configured}

      keys ->
        with {:ok, id} <- Signature.single_header(conn, "x-alert-key"),
             %{secret: secret} <- Enum.find(keys, &(&1.id == id)),
             {:ok, timestamp} <- Signature.single_header(conn, "x-alert-timestamp"),
             {:ok, signature} <- Signature.single_header(conn, "x-alert-signature"),
             true <- Signature.fresh?(timestamp, System.os_time(:second), @tolerance_s),
             true <- Signature.valid_hex?(signature, [secret], [timestamp, ".", raw]) do
          :ok
        else
          _ -> {:error, :unauthorized}
        end
    end
  end

  @doc """
  The delivery's key for the ingress: `"<key id>:<timestamp>"`, from the headers `verify/2`
  has already checked. It carries the key to `enqueue/3`, which takes its organization from
  it, and the timestamp, which a provider with no alert id of its own puts in the event id.
  """
  @spec dedup_key(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :bad_request}
  def dedup_key(conn) do
    with {:ok, id} <- Signature.single_header(conn, "x-alert-key"),
         true <- Regex.match?(@key_id, id),
         {:ok, timestamp} <- Signature.single_header(conn, "x-alert-timestamp"),
         true <- Regex.match?(@timestamp, timestamp) do
      {:ok, id <> ":" <> timestamp}
    else
      _ -> {:error, :bad_request}
    end
  end

  @doc """
  Records the alerts `parse` reads from `payload` in the organization of the key named in
  `dedup_key`. `parse` gets the payload and the signed timestamp and returns the alerts.
  """
  @spec enqueue(map(), String.t(), String.t(), (map(), String.t() -> [alert()])) ::
          {:ok, :enqueued | :duplicate | :ignored} | {:reject, atom()} | {:error, atom()}
  def enqueue(payload, dedup_key, provider, parse) do
    with [id, timestamp] <- String.split(dedup_key, ":", parts: 2),
         %{organization_id: organization} <- Enum.find(keys(), &(&1.id == id)) do
      case parse.(payload, timestamp) do
        [] -> {:reject, :no_alerts}
        alerts -> record(organization, provider, alerts)
      end
    else
      # The key was removed between verify and enqueue: nothing to record it under.
      _ -> {:error, :not_configured}
    end
  end

  defp record(organization, provider, alerts) do
    case Occurrences.record_alerts(organization, provider, alerts) do
      {:ok, 0} -> {:ok, :duplicate}
      {:ok, _created} -> {:ok, :enqueued}
      # Never log or return the error: it may carry the payload's values.
      {:error, _} -> {:error, :insert_failed}
    end
  end

  @doc "A label value as a short fact: text cut to 120 characters, anything else `nil`."
  @spec label(term()) :: String.t() | nil
  def label(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, 120) do
      "" -> nil
      text -> text
    end
  end

  def label(_value), do: nil

  @doc "An id-shaped string (letters, digits and `:_-.`, at most 128), or `nil`."
  @spec id(term()) :: String.t() | nil
  def id(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z0-9:_\-.]{1,128}\z/, do: value, else: nil
  end

  def id(value) when is_integer(value) and value >= 0, do: Integer.to_string(value)
  def id(_value), do: nil
end
