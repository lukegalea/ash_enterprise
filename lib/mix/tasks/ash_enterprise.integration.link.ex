defmodule Mix.Tasks.AshEnterprise.Integration.Link do
  @shortdoc "Links an existing Nango connection to a user as one of their linked accounts"

  @moduledoc """
  Records that one of a user's provider accounts is reachable through an
  existing Nango connection (ADR 0011), and opens the account's erasure scope
  (ADR 0024), so it is shreddable from the moment it exists.

      mix ash_enterprise.integration.link --email you@example.com \\
        --integration google-mail --connection-id <nango connection id> [--label work]

  * `--integration` is one of `google-calendar`, `google-mail`, `slack` — the
    Nango integration (provider config key) the connection belongs to.
  * `--connection-id` is the Nango connection id from the OAuth click-through.
    It is a handle the Nango secret key spends, so it is never printed back in
    full.
  * The link is made **as the user named by `--email`**, under their own
    grants (`create` on `AshEnterprise.Integration.LinkedAccount`): a linked
    account is always owned by the person whose account it is.

  Prints the new linked account's id and its erasure scope, `connection:<id>`
  — the name `mix ash_enterprise.erasure.shred` takes. Then run a step by hand
  (`mix ash_enterprise.integration.sync --linked-account <id>`) or let the
  scheduler pick it up. See `docs/runbooks/crypto-shredding.md`.
  """

  use Mix.Task

  alias AshEnterprise.Integration.{Console, Landing, LinkedAccount}
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Security.ActorContext

  @requirements ["app.config"]

  @switches [email: :string, integration: :string, connection_id: :string, label: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: @switches)

    email = opts[:email] || Mix.raise("--email <user> is required")
    integration = integration!(opts[:integration])
    connection_id = opts[:connection_id] || Mix.raise("--connection-id <id> is required")

    # Repo only: no Oban, no endpoint (iron law #23).
    Helpers.boot_repo()

    actor =
      case Console.actor_for_email(email) do
        {:ok, actor} -> actor
        {:error, :no_such_user} -> Mix.raise("no user with email #{email}")
      end

    account = link!(actor, email, integration, connection_id, opts[:label])

    case Landing.open(account) do
      {:ok, _scope} -> :ok
      {:error, reason} -> Mix.raise("linked, but its erasure scope did not open: #{reason}")
    end

    {scope, status} = Console.scope_of(account)

    Mix.shell().info(
      "Linked #{integration} account #{account.id} for #{email} " <>
        "(connection #{Console.masked(connection_id)}).\n" <>
        "Erasure scope: #{scope} (#{status})."
    )
  end

  defp link!(actor, email, integration, connection_id, label) do
    LinkedAccount.link(
      %{provider_config_key: integration, connection_id: connection_id, label: label},
      actor: actor,
      tenant: ActorContext.tenant(actor)
    )
    |> case do
      {:ok, account} ->
        account

      {:error, %Ash.Error.Forbidden{}} ->
        Mix.raise("#{email} holds no grant to create linked accounts; nothing was linked.")

      {:error, error} ->
        # Field names and messages only: the connection id is sensitive, so
        # an error's value is never echoed.
        fields =
          error
          |> Ash.Error.to_error_class()
          |> Map.get(:errors, [])
          |> Enum.map_join(", ", &"#{Map.get(&1, :field) || "link"}: #{Map.get(&1, :message)}")

        Mix.raise("link refused: #{fields}")
    end
  end

  defp integration!(key) when is_binary(key) do
    if key in Console.integrations(),
      do: key,
      else: Mix.raise("--integration must be one of #{Enum.join(Console.integrations(), ", ")}")
  end

  defp integration!(_key),
    do: Mix.raise("--integration is required: #{Enum.join(Console.integrations(), ", ")}")
end
