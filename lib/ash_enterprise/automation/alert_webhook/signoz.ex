defmodule AshEnterprise.Automation.AlertWebhook.Signoz do
  @moduledoc """
  SigNoz alerts on the inbound alert webhook (`AshEnterprise.Automation.AlertWebhook`,
  `POST /webhooks/alerts-signoz`).

  SigNoz's webhook channel sends Alertmanager's shape: `alerts`, each with a `status`
  (`firing` or `resolved`), `labels` (the rule's labels plus `alertname` and `ruleId`),
  `startsAt` and a `fingerprint`. Each alert is one occurrence, typed `alert.<status>`,
  whose `event_id` is `signoz:<fingerprint>:<startsAt>:<status>`: a renotification of an
  alert still firing is the same occurrence, and its resolution is another. An alert
  without a fingerprint or a known status is skipped; a body with none left is refused
  (400). Only `alertname`, `severity`, `category` and `ruleId` are kept.
  """

  @behaviour AshOperations.Webhook.Provider

  alias AshEnterprise.Automation.AlertWebhook

  @provider "signoz"
  @max_alerts 20
  @statuses %{"firing" => "alert.firing", "resolved" => "alert.resolved"}

  @impl AshOperations.Webhook.Provider
  def max_body_bytes, do: 65_536

  @impl AshOperations.Webhook.Provider
  def verify(conn, raw), do: AlertWebhook.verify(conn, raw)

  @impl AshOperations.Webhook.Provider
  def dedup_key(conn, _payload), do: AlertWebhook.dedup_key(conn)

  @impl AshOperations.Webhook.Provider
  def enqueue(payload, key), do: AlertWebhook.enqueue(payload, key, @provider, &alerts/2)

  @doc "The alerts in a SigNoz payload, as occurrence attributes. See the moduledoc."
  @spec alerts(map(), String.t()) :: [AlertWebhook.alert()]
  def alerts(%{"alerts" => alerts}, _timestamp) when is_list(alerts) do
    alerts
    |> Enum.take(@max_alerts)
    |> Enum.flat_map(&alert/1)
  end

  def alerts(_payload, _timestamp), do: []

  defp alert(%{"status" => status, "fingerprint" => fingerprint} = alert) do
    labels = if is_map(alert["labels"]), do: alert["labels"], else: %{}
    starts_at = AlertWebhook.id(alert["startsAt"]) || "unknown"

    with {:ok, type} <- Map.fetch(@statuses, status),
         fingerprint when is_binary(fingerprint) <- AlertWebhook.id(fingerprint) do
      rule_id = AlertWebhook.id(labels["ruleId"])

      [
        %{
          event_id: "#{@provider}:#{fingerprint}:#{starts_at}:#{status}",
          type: type,
          subject: nil,
          time: time(alert["startsAt"]),
          data: %{
            "provider" => @provider,
            "alertname" => AlertWebhook.label(labels["alertname"]),
            "severity" => AlertWebhook.label(labels["severity"]),
            "category" => AlertWebhook.label(labels["category"]),
            "rule_id" => rule_id
          }
        }
      ]
    else
      _ -> []
    end
  end

  defp alert(_alert), do: []

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> DateTime.utc_now()
    end
  end

  defp time(_value), do: DateTime.utc_now()
end
