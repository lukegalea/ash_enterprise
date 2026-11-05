defmodule Mix.Tasks.AshEnterprise.Demo do
  @shortdoc "Create or refresh the demo tenant: a business-unit tree, people, a clinic, an MDM walk-through"

  @moduledoc """
  Create, or refresh, the demo tenant (`AshEnterprise.Platform.DemoTenant`, the
  organization `clinic-demo`) and fill it.

      mix ash_enterprise.demo

  It writes to that tenant and to no other, so it is safe to run on a database that
  already holds real tenants: it never chooses among them, and running it twice changes
  nothing the second time. The demo administrator is `demo-admin@example.com`
  (password1234); `mix ash_enterprise.seed` is not needed first.

  A tenant with one business unit and one Administrator demonstrates no hierarchy and no
  scoping, so this adds a three-division tree (one of them two deep), nine people spread
  unevenly across it, three teams, and three roles that differ in grant *depth*
  rather than only in name; and a synthetic clinic whose credentials are activated
  through governed invocations, with requests already waiting and decided, and whose
  licence documents an agent reads into findings
  (`AshEnterprise.Credentialing.DemoData`, toured at `/app/showcase/credentialing`).
  Everything is created through the application's own actions, and it is
  idempotent by name, so re-running it changes nothing.
  """

  use Mix.Task

  alias AshEnterprise.Platform.DemoTenant

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    # DemoData opens an import batch through Oban and the confirmation
    # add-on renders URLs from the endpoint — the full app, once, is the
    # honest boot (a standalone Repo would collide with app.start later).
    Mix.Task.run("app.start")

    %{organization: organization, counts: counts, clinic: clinic, mdm: mdm} = DemoTenant.run!()

    Mix.shell().info("""

    Populated "#{organization.name}" (#{organization.unique_name}), the only tenant the demo writes to:

      business units  #{counts.business_units}
      people          #{counts.users}
      teams           #{counts.teams}
      roles           #{counts.roles}

    Clinic credentialing (password1234):
      #{clinic.clinic.name}: #{length(clinic.clinicians)} clinicians, #{length(clinic.credentials)} credentials
      requests        #{Enum.map_join(clinic.requests, ", ", &Atom.to_string(&1.status))}
      coordinator     #{clinic.coordinator.email}
      committee       #{Enum.map_join(clinic.committee, ", ", &to_string(&1.email))}
      directors       #{clinic.director.email}, #{clinic.deputy.email}
      documents       #{length(clinic.documents)}, read by the licence reader (recorded model turns)
      workspace       /app/credentialing
      guided tour     /app/showcase/credentialing
    """)

    if mdm do
      Mix.shell().info("""
      MDM demo (#{DemoTenant.admin_email()} / password1234):
        import a CSV     /app/mdm/import
        steward queue    /app/mdm      (#{mdm.review_pending} review waiting)
        golden records   /app/mdm/golden
        process model    /app/processes  (mdm.steward_review BPMN; banding is a DMN table)
      """)
    end
  end
end
