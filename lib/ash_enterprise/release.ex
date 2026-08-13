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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
