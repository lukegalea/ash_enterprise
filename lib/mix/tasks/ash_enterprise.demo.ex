defmodule Mix.Tasks.AshEnterprise.Demo do
  @shortdoc "Populate the seeded tenant with a business-unit tree, people, teams and roles"

  @moduledoc """
  Fill out the tenant `mix ash_enterprise.seed` provisions.

      mix ash_enterprise.demo

  The seed task deliberately creates the minimum: one organization, one business
  unit, one Administrator. That is right for a first run and for tests, and
  wrong for looking at the application — a hierarchy with one node demonstrates
  no hierarchy, and a security model with one role demonstrates no scoping.

  This adds a three-division tree (one of them two deep), nine people spread
  unevenly across it, three teams, and three roles that differ in grant *depth*
  rather than only in name. Everything is created through the application's own
  actions, and it is idempotent by name, so re-running it changes nothing.

  Run `mix ash_enterprise.seed` first — this needs a tenant to populate, and
  fails with that instruction if it does not find one.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [organization: :string])

    organization = organization!(opts[:organization])

    counts = AshEnterprise.Platform.DemoData.populate(organization.id)

    Mix.shell().info("""

    Populated "#{organization.name}":

      business units  #{counts.business_units}
      people          #{counts.users}
      teams           #{counts.teams}
      roles           #{counts.roles}

    Everyone signs in with password1234. Visit /app/business-units, /app/users,
    /app/teams and /app/roles.
    """)
  end

  # Two of the organizations in a seeded database are not tenants, and both would
  # be wrong to populate.
  #
  # The legacy estate is usually the FIRST one -- `seed_legacy_estate/0` runs
  # before `seed_tenant/1` because the strangler view needs its ids -- so taking
  # whichever came back first fills the simulated 2010-era estate with people who
  # never existed in it, wrongly and invisibly until someone reads the legacy
  # screens.
  #
  # The platform organization holds the baselines this application publishes
  # centrally. `Seeder.seed_platform_organization/0` says in its own docs that a
  # tenant listing shown to a human should exclude it; this is such a listing,
  # and leaving it in made the documented quickstart -- seed, then demo -- fail
  # on a fresh database with "which one did you mean", naming two organizations
  # a reader has no reason to be choosing between.
  defp organization!(nil) do
    legacy_id = AshEnterprise.Legacy.Estate.organization_id()
    platform = AshEnterprise.Platform.Seeder.platform_unique_name()

    tenants =
      Enum.reject(all_organizations(), fn organization ->
        to_string(organization.id) == legacy_id or
          to_string(organization.unique_name) == platform
      end)

    case tenants do
      [organization] ->
        organization

      [] ->
        Mix.raise("""
        No tenant to populate — the only organization is the legacy estate.

        Run `mix ash_enterprise.seed` first. It provisions the organization, the
        root business unit and the Administrator that this task builds on.
        """)

      many ->
        Mix.raise("""
        #{length(many)} organizations, so which one to populate is ambiguous:

        #{Enum.map_join(many, "\n", fn organization -> "  #{organization.id}  #{organization.name}" end)}

        Name one with `mix ash_enterprise.demo --organization <id>`.
        """)
    end
  end

  defp organization!(id) do
    case Enum.find(all_organizations(), &(to_string(&1.id) == id)) do
      nil -> Mix.raise("No organization with id #{inspect(id)}.")
      organization -> organization
    end
  end

  defp all_organizations do
    Ash.read!(AshEnterprise.Accounts.Organization, authorize?: false)
  end
end
