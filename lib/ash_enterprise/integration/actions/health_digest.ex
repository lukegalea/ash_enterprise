defmodule AshEnterprise.Integration.Actions.HealthDigest do
  @moduledoc """
  `LinkedAccount.health_digest`: the linked accounts the actor can see, as
  plain text for a terminal transcript (the ACP `accounts` prompt) — provider,
  health, last sync, reach. Structure only: no label, no connection id, no
  content.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Integration.LinkedAccount

  @impl true
  def run(_input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    LinkedAccount
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.load([:provider, :health, :last_sync, :reach, :projection])
    |> Ash.Query.sort(:provider_config_key)
    |> Ash.read(opts)
    |> case do
      {:ok, accounts} -> {:ok, render(accounts)}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def render([]), do: "Accounts & syncs — no linked accounts."

  def render(accounts) do
    lines =
      Enum.map(accounts, fn account ->
        "  #{account.provider}  · #{account.health}  · last sync #{account.last_sync}" <>
          "  · #{account.reach}  · projected #{account.projection}"
      end)

    blocked = Enum.count(accounts, &String.starts_with?(&1.health, "Blocked"))
    summary = if blocked > 0, do: " (#{blocked} blocked)", else: ""

    Enum.join(["Accounts & syncs — #{length(accounts)} linked#{summary}" | lines], "\n")
  end
end
