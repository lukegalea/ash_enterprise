defmodule AshEnterprise.Assistant.Lookups.Accounts do
  @moduledoc """
  `Lookup.Account.my_accounts`: the person's own active linked accounts
  (`AshEnterprise.Integration.LinkedAccount`'s `mine`), as that person reads them:
  the provider's name (Gmail, Google Calendar, Slack), the account's label, how its
  sync stands and when it last synced. At most #{20}.
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Integration.LinkedAccount

  @shown 20

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, fn opts ->
      LinkedAccount
      |> Ash.Query.for_read(:mine, %{}, opts)
      |> Ash.Query.filter(lifecycle_status == :active)
      |> Ash.Query.sort(provider_config_key: :asc, label: :asc)
      |> Ash.Query.load([:provider, :health, :last_sync])
      |> Ash.Query.limit(@shown)
      |> Ash.read(opts)
      |> case do
        {:ok, accounts} -> {:ok, Enum.map(accounts, &row/1)}
        error -> error
      end
    end)
  end

  defp row(account) do
    Support.row(Lookup.Account, %{
      id: account.id,
      provider: account.provider,
      label: Support.text(account.label),
      health: account.health,
      last_sync: account.last_sync
    })
  end
end
