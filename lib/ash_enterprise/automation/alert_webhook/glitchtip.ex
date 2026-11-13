defmodule AshEnterprise.Automation.AlertWebhook.Glitchtip do
  @moduledoc """
  GlitchTip alerts on the inbound alert webhook (`AshEnterprise.Automation.AlertWebhook`,
  `POST /webhooks/alerts-glitchtip`).

  GlitchTip's webhook sends a Slack-shaped body: `attachments`, one per issue, each with a
  `title` and a `title_link` ending in `/issues/<id>`. Each issue is one `alert.firing`
  occurrence. GlitchTip gives an alert no id of its own, so the `event_id` is
  `glitchtip:<issue>:<signed timestamp>`: a replay of one request records nothing new, and
  a later alert for the same issue is another occurrence. An attachment without an issue
  link is skipped; a body with none left is refused (400). Only the title is kept, as
  `alertname`, with `category` `error`.
  """

  @behaviour AshOperations.Webhook.Provider

  alias AshEnterprise.Automation.AlertWebhook

  @provider "glitchtip"
  @max_alerts 20
  @issue ~r"/issues/([0-9]{1,20})/?\z"

  @impl AshOperations.Webhook.Provider
  def max_body_bytes, do: 65_536

  @impl AshOperations.Webhook.Provider
  def verify(conn, raw), do: AlertWebhook.verify(conn, raw)

  @impl AshOperations.Webhook.Provider
  def dedup_key(conn, _payload), do: AlertWebhook.dedup_key(conn)

  @impl AshOperations.Webhook.Provider
  def enqueue(payload, key), do: AlertWebhook.enqueue(payload, key, @provider, &alerts/2)

  @doc "The alerts in a GlitchTip payload, as occurrence attributes. See the moduledoc."
  @spec alerts(map(), String.t()) :: [AlertWebhook.alert()]
  def alerts(%{"attachments" => attachments}, timestamp) when is_list(attachments) do
    attachments
    |> Enum.take(@max_alerts)
    |> Enum.flat_map(&alert(&1, timestamp))
    |> Enum.uniq_by(& &1.event_id)
  end

  def alerts(_payload, _timestamp), do: []

  defp alert(%{"title_link" => link} = attachment, timestamp) when is_binary(link) do
    case Regex.run(@issue, link) do
      [_, issue] ->
        [
          %{
            event_id: "#{@provider}:#{issue}:#{timestamp}",
            type: "alert.firing",
            subject: nil,
            data: %{
              "provider" => @provider,
              "alertname" => AlertWebhook.label(attachment["title"]),
              "category" => "error",
              "rule_id" => "issue:#{issue}"
            }
          }
        ]

      _ ->
        []
    end
  end

  defp alert(_attachment, _timestamp), do: []
end
