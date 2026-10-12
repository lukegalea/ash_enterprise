defmodule AshEnterprise.Integration.Calculations.AccountHealth do
  @moduledoc """
  A linked account's sync health written for a person — structure only, never
  content and never the connection id:

    * `field: :provider` — `Google Calendar`, `Gmail`, `Slack`
    * `field: :health` — `Syncing`, `Blocked · unauthorized`, `Paused`,
      `Not synced yet`
    * `field: :last_sync` — `Mon 12 Oct 09:30 · 12 min ago`, or `never`
    * `field: :reach` — what the sync covers so far: `3 calendars`,
      `12 Slack conversations`, `Gmail: incremental`
    * `field: :projection` — when landed mail was last projected into the
      canonical model (Gmail, Slack), or `With each sync` (calendar)

  Reads the cursor aggregates on `LinkedAccount`, so everything is loaded
  under the reading actor's policies.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Platform.LocalTime

  @fields [:provider, :health, :last_sync, :reach, :projection]

  @impl true
  def init(opts) do
    if opts[:field] in @fields,
      do: {:ok, opts},
      else: {:error, "field must be one of #{inspect(@fields)}"}
  end

  @impl true
  def load(_query, _opts, _context) do
    [
      :provider_config_key,
      :lifecycle_status,
      :sync_blocked_reason,
      :sync_blocked_at,
      :calendar_synced_at,
      :calendar_count,
      :gmail_synced_at,
      :gmail_phase,
      :slack_synced_at,
      :slack_conversation_count,
      :projected_at
    ]
  end

  @impl true
  def calculate(accounts, opts, _context) do
    {:ok, Enum.map(accounts, &value(&1, opts[:field]))}
  end

  @doc "The provider's display name for an integration key."
  def provider("google-calendar"), do: "Google Calendar"
  def provider("google-mail"), do: "Gmail"
  def provider("slack"), do: "Slack"
  def provider(other), do: other

  @doc "The newest sync time across the account's cursors, or nil."
  def last_synced_at(account) do
    [account.calendar_synced_at, account.gmail_synced_at, account.slack_synced_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp value(account, :provider), do: provider(account.provider_config_key)

  defp value(account, :health) do
    cond do
      account.sync_blocked_at -> "Blocked · #{account.sync_blocked_reason}"
      account.lifecycle_status == :inactive -> "Paused"
      is_nil(last_synced_at(account)) -> "Not synced yet"
      true -> "Syncing"
    end
  end

  defp value(account, :last_sync) do
    case last_synced_at(account) do
      nil -> "never"
      at -> "#{LocalTime.stamp(at)} · #{LocalTime.ago(at)}"
    end
  end

  defp value(%{provider_config_key: "google-calendar"} = account, :reach),
    do: count(account.calendar_count, "calendar")

  defp value(%{provider_config_key: "slack"} = account, :reach),
    do: count(account.slack_conversation_count, "conversation")

  defp value(%{provider_config_key: "google-mail"} = account, :reach) do
    case account.gmail_phase do
      nil -> "No mailbox cursor yet"
      phase -> "Mailbox · #{phase}"
    end
  end

  defp value(_account, :reach), do: ""

  # The calendar projects inline with each step; the mail verticals keep a
  # projection watermark of their own (`Integration.ProjectionCursor`).
  defp value(%{provider_config_key: "google-calendar"}, :projection), do: "With each sync"
  defp value(%{projected_at: nil}, :projection), do: "Not projected yet"

  defp value(%{projected_at: at}, :projection),
    do: "#{LocalTime.stamp(at)} · #{LocalTime.ago(at)}"

  defp count(n, noun) when n in [nil, 0], do: "No #{noun}s yet"
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
