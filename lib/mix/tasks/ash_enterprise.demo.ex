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
  rather than only in name; and a synthetic clinic whose credentials wait to be
  activated through a governed invocation (`AshEnterprise.Credentialing.DemoData`).
  Everything is created through the application's own actions, and it is
  idempotent by name, so re-running it changes nothing.

  Run `mix ash_enterprise.seed` first — this needs a tenant to populate, and
  fails with that instruction if it does not find one.
  """

  use Mix.Task

  require Ash.Query

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [organization: :string])

    # DemoData opens an import batch through Oban and the confirmation
    # add-on renders URLs from the endpoint — the full app, once, is the
    # honest boot (a standalone Repo would collide with app.start later).
    Mix.Task.run("app.start")

    organization = organization!(opts[:organization])

    counts = AshEnterprise.Platform.DemoData.populate(organization.id)
    clinic = AshEnterprise.Credentialing.DemoData.populate(organization.id)

    admin =
      AshEnterprise.Accounts.User
      |> Ash.Query.filter(email == ^"admin@example.com")
      |> Ash.read_one!(tenant: organization.id, authorize?: false)

    mdm =
      if admin do
        AshEnterprise.Mdm.DemoData.populate(organization.id, admin)
      else
        nil
      end

    Mix.shell().info("""

    Populated "#{organization.name}":

      business units  #{counts.business_units}
      people          #{counts.users}
      teams           #{counts.teams}
      roles           #{counts.roles}

    Clinic credentialing (password1234):
      #{clinic.clinic.name}: #{length(clinic.clinicians)} clinicians, #{length(clinic.credentials)} credentials to activate
      coordinator     #{clinic.coordinator.email}
      committee       #{Enum.map_join(clinic.committee, ", ", &to_string(&1.email))}
    """)

    if mdm do
      Mix.shell().info("""
      MDM demo (admin@example.com / password1234):
        import a CSV     /app/mdm/import
        steward queue    /app/mdm      (#{mdm.review_pending} review waiting)
        golden records   /app/mdm/golden
        process model    /app/processes  (mdm.steward_review BPMN; banding is a DMN table)
      """)
    else
      Mix.shell().info(
        "  (no admin@example.com user found — run `mix ash_enterprise.seed` first for the MDM demo)"
      )
    end
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
