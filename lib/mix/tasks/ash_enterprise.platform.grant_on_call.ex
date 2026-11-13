defmodule Mix.Tasks.AshEnterprise.Platform.GrantOnCall do
  @shortdoc "Gives existing tenants the starter On-call role (dry run unless --apply)"

  @moduledoc """
  Makes sure each tenant has the starter **On-call** role: the candidates of
  the `incident_triage` pack's triage task, holding read on incidents.
  Administrators do not hold it implicitly. See
  `AshEnterprise.Platform.Seeder.ensure_on_call_role/2`.

      mix ash_enterprise.platform.grant_on_call                  # every tenant, dry run
      mix ash_enterprise.platform.grant_on_call --tenant acme    # one tenant (unique_name or id)
      mix ash_enterprise.platform.grant_on_call --apply          # write it

  A new tenant gets the role when it is seeded; this is for tenants
  provisioned before the role existed. Idempotent and additive: it creates the
  role if missing and adds the grants it lacks, never removes one, and assigns
  the role to nobody — an administrator does that in the role admin.

  It does not run at boot on purpose: adding a role to a customer's tenant is
  a deliberate act, so it is dry-run by default and prints what it would do.
  """

  use Mix.Task

  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Platform.Seeder

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv, strict: [tenant: :string, apply: :boolean])

    # Repo only: no Oban, no endpoint (iron law #23).
    Helpers.boot_repo()

    dry_run? = not Keyword.get(opts, :apply, false)

    reports = Seeder.regrant_on_call(tenant: opts[:tenant], dry_run?: dry_run?)

    Enum.each(reports, &Mix.shell().info(describe(&1)))

    if dry_run?, do: Mix.shell().info("\nDry run: nothing was written. Re-run with --apply.")
  end

  @doc false
  def describe(%{tenant: tenant, role: role, added: added}) do
    grants =
      case added do
        [] ->
          "no grants to add"

        added ->
          Enum.map_join(added, ", ", fn {resource, verb, depth} ->
            "#{resource} #{verb} (#{depth})"
          end)
      end

    "#{tenant}: On-call #{role}; #{grants}"
  end
end
