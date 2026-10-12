defmodule Mix.Tasks.AshEnterprise.Integration.Accounts do
  @shortdoc "Lists a user's linked accounts with their erasure scopes"

  @moduledoc """
  Lists one user's linked accounts — id, integration, label, lifecycle status,
  the masked connection id, and the erasure scope each one lands under, as the
  erasure tasks name it.

      mix ash_enterprise.integration.accounts --email you@example.com

      9b0f…  google-mail  work  active  connection ****a1b2  scope connection:9b0f… (active)

  The scope is `connection:<linked account id>`: pass it to
  `mix ash_enterprise.erasure.shred` to erase everything that came in through
  that account. Note it down **before** unlinking: once the linked account is
  gone, its scope is still listed by `mix ash_enterprise.erasure.scopes`, but
  only by that id and its integration.

  Read as the user named by `--email`, under their own grants. Structural
  facts only.
  """

  use Mix.Task

  alias AshEnterprise.Integration.{Console, LinkedAccount}
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Security.ActorContext

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [email: :string])
    email = opts[:email] || Mix.raise("--email <user> is required")

    # Repo only: no Oban, no endpoint (iron law #23).
    Helpers.boot_repo()

    actor =
      case Console.actor_for_email(email) do
        {:ok, actor} -> actor
        {:error, :no_such_user} -> Mix.raise("no user with email #{email}")
      end

    accounts =
      case LinkedAccount.mine(nil, %{}, actor: actor, tenant: ActorContext.tenant(actor)) do
        {:ok, accounts} -> Enum.sort_by(accounts, &{&1.provider_config_key, &1.inserted_at})
        {:error, %Ash.Error.Forbidden{}} -> Mix.raise("#{email} may not read linked accounts")
        {:error, _error} -> Mix.raise("could not read #{email}'s linked accounts")
      end

    if accounts == [] do
      Mix.shell().info("#{email} has no linked accounts.")
    else
      Enum.each(accounts, &Mix.shell().info(line(&1)))
    end
  end

  defp line(account) do
    {scope, status} = Console.scope_of(account)

    Enum.join(
      [
        account.id,
        account.provider_config_key,
        account.label || "-",
        account.lifecycle_status,
        "connection #{Console.masked(account.connection_id)}",
        "scope #{scope} (#{status})"
      ],
      "  "
    )
  end
end
