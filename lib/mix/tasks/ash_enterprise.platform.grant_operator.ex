defmodule Mix.Tasks.AshEnterprise.Platform.GrantOperator do
  @shortdoc "Makes a user the platform operator: raw landings and erasure scopes, every tenant"

  @moduledoc """
  Grants one user the operator-only privileges
  (`AshEnterprise.Security.Privilege.operator_only?/1`): read raw provider
  landings (`AshEnterprise.Ingestion.SourceObject`) and open and shred erasure
  scopes (`AshEnterprise.Erasure.Scope`), across every tenant.

      mix ash_enterprise.platform.grant_operator --email you@example.com

  No tenant's Administrator holds these: the resources are untenanted, so a
  grant on them reaches every tenant's rows. This task is the one way to grant
  them (it runs as the `seed` system actor; a role grant of an operator-only
  privilege by anyone else is refused). It creates a `Platform Operator` role
  in the user's tenant, grants it the privileges at `global` depth, and
  assigns it to the user. Idempotent.

  Needed before `mix ash_enterprise.erasure.shred --as <you>`.
  """

  use Mix.Task

  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Platform.Seeder

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [email: :string])
    email = opts[:email] || Mix.raise("--email <user> is required")

    # Repo only: no Oban, no endpoint (iron law #23).
    Helpers.boot_repo()

    # Operator console: there is no actor until the lookup makes one; the
    # grant itself runs as the seed system actor.
    user =
      case AshEnterprise.Accounts.get_user_by_email(email, authorize?: false) do
        {:ok, user} -> user
        {:error, _} -> Mix.raise("no user with email #{email}")
      end

    revoked = Seeder.revoke_operator_privileges_from_administrators()
    %{role: role, granted: granted} = Seeder.grant_platform_operator(user)

    Mix.shell().info(
      "#{email} holds the #{role.name} role (#{granted} operator-only privileges, global)." <>
        if(revoked > 0,
          do: "\nRemoved #{revoked} operator-only grants from Administrator roles.",
          else: ""
        )
    )
  end
end
