defmodule Mix.Tasks.AshEnterprise.Demo do
  @shortdoc "Create or refresh the demo tenant: a business-unit tree, people, a clinic, an MDM walk-through"

  @moduledoc """
  Create, or refresh, the demo tenant (`AshEnterprise.Platform.DemoTenant`, the
  organization `clinic-demo`) and fill it.

      mix ash_enterprise.demo

  It writes to that tenant and to no other, so it is safe to run on a database that
  already holds real tenants: it never chooses among them, and running it twice changes
  nothing the second time. The demo administrator is `demo-admin@example.com`;
  `mix ash_enterprise.seed` is not needed first.

  ## Passwords

  By default every demo person signs in with the fixed password `password1234`. That is for
  local development only: anyone can read it here.

  On an instance other people can reach, name a file:

      mix ash_enterprise.demo --password-file PATH

  The demo people get the password in that file. When the file does not exist, a random one
  is generated and written to it (mode 0600, the directory created), and it is never
  printed. A re-run does not reset the password of a person who already exists, whatever
  the file now holds; to change it, change it in the application.

  ## History

      mix ash_enterprise.demo --history [--password-file PATH]

  After filling the tenant, runs the tour's fault-driven beats once
  (`AshEnterprise.Showcase.History`), so an instance whose fault panel is off still shows
  a real record of each failure: F4, F5, F2, F3, F1, F7, F6 and F10. They run in this
  process, through the application's own actions; the two that arm a fault point arm it in
  this node only and disarm it afterwards. This node's Oban fetches nothing on its own and runs no sweep, and
  holds the jobs it inserts so that no other node runs them
  (`AshEnterprise.Showcase.History.HeldJobs`). It writes to the demo tenant only, and a
  second run changes nothing. It prints a line per beat and fails when a beat did not end
  in its failure.

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
  alias AshEnterprise.Showcase.History
  alias AshEnterprise.Showcase.History.HeldJobs

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [password_file: :string, history: :boolean])

    # The history seed's node must not fetch, sweep or lead on a database a server polls,
    # and must hold the jobs it inserts: set before the application starts its Oban.
    if opts[:history] do
      config = Application.fetch_env!(:ash_enterprise, Oban)
      Application.put_env(:ash_enterprise, Oban, HeldJobs.oban_config(config))
    end

    # DemoData opens an import batch through Oban and the confirmation
    # add-on renders URLs from the endpoint — the full app, once, is the
    # honest boot (a standalone Repo would collide with app.start later).
    Mix.Task.run("app.start")

    %{organization: organization, counts: counts, clinic: clinic, mdm: mdm} =
      DemoTenant.run!(password_opts(opts))

    Mix.shell().info("""

    Populated "#{organization.name}" (#{organization.unique_name}), the only tenant the demo writes to:

      business units  #{counts.business_units}
      people          #{counts.users}
      teams           #{counts.teams}
      roles           #{counts.roles}

    Clinic credentialing (#{password_note(opts)}):
      #{clinic.clinic.name}: #{length(clinic.clinicians)} clinicians, #{length(clinic.credentials)} credentials
      requests        #{Enum.map_join(clinic.requests, ", ", &Atom.to_string(&1.status))}
      coordinator     #{clinic.coordinator.email}
      committee       #{Enum.map_join(clinic.committee, ", ", &to_string(&1.email))}
      directors       #{clinic.director.email}, #{clinic.deputy.email}
      documents       #{length(clinic.documents)}, read by the licence reader (recorded model turns)
      workspace       /app/credentialing
      guided tour     /app/showcase/credentialing
      compared        /app/quality/compare  (the reader's two versions on one suite)
    """)

    if mdm do
      Mix.shell().info("""
      MDM demo (#{DemoTenant.admin_email()}, #{password_note(opts)}):
        import a CSV     /app/mdm/import
        steward queue    /app/mdm      (#{mdm.review_pending} review waiting)
        golden records   /app/mdm/golden
        process model    /app/processes  (mdm.steward_review BPMN; banding is a DMN table)
      """)
    end

    if opts[:history], do: history!(organization)
  end

  defp history!(organization) do
    report = History.run!(organization)

    lines =
      Enum.map_join(report, "\n", fn entry ->
        "  beat #{entry.beat} (#{Enum.join(entry.failures, ", ")})  " <>
          "#{status(entry.status)}  #{entry.ref}"
      end)

    Mix.shell().info("History, in the tour at /app/showcase/credentialing:\n" <> lines)

    unless History.complete?(report) do
      Mix.raise("a history beat did not end in its failure; see the lines above")
    end
  end

  defp status(:produced), do: "recorded"
  defp status(:already), do: "already recorded"
  defp status({:skipped, why}), do: "skipped (#{why})"
  defp status({:not_produced, observed}), do: "NOT PRODUCED, observed #{inspect(observed)}"

  defp password_opts(opts) do
    case opts[:password_file] do
      nil -> []
      path -> [password: DemoTenant.password_from_file!(path)]
    end
  end

  defp password_note(opts) do
    case opts[:password_file] do
      nil -> "password1234"
      path -> "password in #{path}"
    end
  end
end
