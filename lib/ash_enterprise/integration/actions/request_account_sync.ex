defmodule AshEnterprise.Integration.Actions.RequestAccountSync do
  @moduledoc """
  `LinkedAccount.sync_now`: "sync now" for one linked account, from the
  Accounts & syncs surface.

  Not a new way to sync — it resolves the account under the actor's own
  policies and hands it to the vertical's existing entry point, which is gated
  exactly as it is everywhere else and resolves the account again as the actor:

    * Google Calendar — `Calendar.Sync.request_sync`
    * Gmail — `Gmail.SyncState.request_sync`
    * Slack — `Slack.Sync.request_sync`

  Each enqueues one step, unique per account, so a click while a step is
  queued is a no-op. Returns a short status line; never a connection id.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Integration.Calculations.AccountHealth
  alias AshEnterprise.Integration.{Calendar, Gmail, LinkedAccount, Slack}

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with {:ok, account} <- Ash.get(LinkedAccount, input.arguments.record_id, opts),
         {:ok, result} <- request(account, opts) do
      {:ok, message(account, result)}
    end
  end

  defp request(%{provider_config_key: "google-calendar", id: id}, opts),
    do: Calendar.Sync.request_sync(%{linked_account_id: id}, opts)

  defp request(%{provider_config_key: "google-mail", id: id}, opts),
    do: Gmail.SyncState.request_sync(%{linked_account_id: id}, opts)

  defp request(%{provider_config_key: "slack", id: id}, opts),
    do: Slack.Sync.request_sync(%{linked_account_id: id}, opts)

  defp request(%{provider_config_key: key}, _opts),
    do: {:error, "no sync is defined for #{key}"}

  defp message(account, result) do
    provider = AccountHealth.provider(account.provider_config_key)

    if already_queued?(result),
      do: "#{provider} sync is already queued.",
      else: "#{provider} sync queued."
  end

  defp already_queued?(%{already_enqueued: true}), do: true
  defp already_queued?(%{conflict?: true}), do: true
  defp already_queued?(_result), do: false
end
