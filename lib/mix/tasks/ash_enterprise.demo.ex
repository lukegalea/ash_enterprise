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

  # The legacy estate is an Organization too, and it is usually the FIRST one --
  # `seed_legacy_estate/0` runs before `seed_tenant/1` because the strangler view
  # needs its ids. Taking whichever came back first therefore populates the
  # simulated 2010-era estate with people who never existed in it, which is both
  # wrong and invisible until someone reads the legacy screens. Exclude it by id
  # and require the choice to be unambiguous.
  defp organization!(nil) do
    legacy_id = AshEnterprise.Legacy.Estate.organization_id()

    case Enum.reject(all_organizations(), &(to_string(&1.id) == legacy_id)) do
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
