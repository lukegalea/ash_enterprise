defmodule AshEnterprise.Release do
  @moduledoc """
  Release tasks. This is how migrations run in production.

  ## Why `mix` is not available here

  A release does not ship Mix. `mix ash.migrate` works in development and does
  not exist on a production node, so migrations have to be invoked as release
  commands:

      bin/ash_enterprise eval "AshEnterprise.Release.migrate()"

  This trips people up because the development command and the production
  command are different, and nothing warns you — the deploy simply runs an
  application whose schema is behind its code.

  ## Ash specifics

  Ash generates migrations from resource snapshots, and the generated files are
  ordinary Ecto migrations, so `Ecto.Migrator` runs them. What differs is the
  ordering guarantee: `mix ash.codegen` may produce a *pair* of migrations (an
  extensions migration and a schema migration), and both must run. Running the
  repo's full pending set, as below, handles that.

  ## Multitenancy note

  This application uses attribute-based multitenancy, so there is exactly one
  schema and one migration path. Had it used schema-based multitenancy, every
  tenant would need its own migration run here — which is the single biggest
  operational cost of that strategy and part of why ADR 0003 did not choose it.
  """

  @app :ash_enterprise

  @doc """
  Runs all pending migrations.

  Safe to run on every deploy: `Ecto.Migrator` skips what has already run.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls a repo back to `version`.

  Deliberately requires an explicit version rather than defaulting to "one
  step". A rollback is a decision someone should have to state precisely, at
  3am, in a command they can read back to a colleague.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Seeds the privilege catalogue.

  Idempotent and safe on every deploy — and it SHOULD run on every deploy,
  because the catalogue is derived from the resource list. A resource added
  without re-seeding has no privileges, which makes access to it ungrantable:
  a silent failure that looks like a permissions bug.

  Tenant provisioning is deliberately NOT here. Creating tenants is a business
  operation, not a deployment step.
  """
  def seed_privileges do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)
    AshEnterprise.Platform.Seeder.seed_privileges()
  end

  @doc """
  Verifies the audit log's hash chains and prints the result, as
  `mix ash_enterprise.audit.verify` does where Mix exists:

      bin/ash_enterprise eval "AshEnterprise.Release.audit_verify()"
      bin/ash_enterprise eval 'AshEnterprise.Release.audit_verify("0198f3a4-...", halt?: true)'

  `tenant` limits it to one organization's chain. Returns the `AshEnterprise.Audit.Verify`
  report. With `halt?: true` a broken chain stops the VM with status 1, so a scheduler or
  a deploy script can act on it. Nothing is written.
  """
  def audit_verify(tenant \\ nil, opts \\ []) do
    load_app()

    # The repo and Ash, not the supervision tree: a verifier must not drain the queues.
    :ok = AshEnterprise.Mix.Helpers.boot_repo()
    report = AshEnterprise.Audit.Verify.report(tenant)

    Enum.each(AshEnterprise.Audit.Verify.lines(report), &IO.puts/1)
    if report.status == :broken and opts[:halt?], do: System.halt(1)
    report
  end

  @doc """
  Writes the audit package for one tenant and period to a directory, as
  `mix ash_enterprise.audit.export` does where Mix exists:

      bin/ash_enterprise eval 'AshEnterprise.Release.audit_export(tenant: "0198f3a4-...", as: "auditor@example.com", from: "2026-01-01", to: "2027-01-01", out: "/tmp/audit-2026")'

  Options are the Mix task's flags, as strings. `{:ok, package}` or `{:error, message}`; a
  broken chain is reported and still written, as the package says so itself.
  """
  def audit_export(opts) do
    load_app()

    :ok = AshEnterprise.Mix.Helpers.boot_repo()
    AshEnterprise.Mix.Helpers.load_domain_resources()
    result = AshEnterprise.Audit.Package.Files.export(opts)

    case result do
      {:ok, package} ->
        {info, errors} = AshEnterprise.Audit.Package.Files.summary(opts[:out], package)
        Enum.each(info, &IO.puts/1)
        Enum.each(errors, &IO.puts(:stderr, &1))

      {:error, message} ->
        IO.puts(:stderr, message)
    end

    result
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
