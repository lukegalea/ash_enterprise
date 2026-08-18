defmodule Mix.Tasks.AshEnterprise.Seed do
  @shortdoc "Seed the privilege catalogue and provision an example tenant"

  @moduledoc """
  Brings a fresh database to a state you can actually sign into and explore.

      mix ash_enterprise.seed
      mix ash_enterprise.seed --email me@example.com --password hunter2hunter2
      mix ash_enterprise.seed --privileges-only

  Two independent things happen:

    * **The privilege catalogue** is derived from the configured domains — one
      privilege per `(resource, verb)`, with legal depths taken from each
      resource's ownership model. This describes the *software*, so it is not
      tenant data and should be re-run after adding resources.

    * **A tenant** is provisioned: organization, root business unit, default
      team, an Administrator role, and a user holding it.

  **Only the privilege half is idempotent**, and that half is the one that
  matters on deploy: re-running it after adding a resource is the intended
  workflow. The tenant half is not — a second run fails with
  `unique_name: has already been taken`, because provisioning an organization
  that already exists is a mistake rather than a no-op. Use `--privileges-only`
  on a database that has already been seeded. (Verified 2026-08-18; this
  moduledoc previously claimed the whole task was idempotent.)
  """

  use Mix.Task

  @switches [
    email: :string,
    password: :string,
    name: :string,
    unique_name: :string,
    privileges_only: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")

    count = AshEnterprise.Platform.Seeder.seed_privileges()

    Mix.shell().info(
      "Seeded #{count} privileges across #{length(AshEnterprise.Platform.Seeder.platform_resources())} resources."
    )

    if opts[:privileges_only] do
      :ok
    else
      seeded = AshEnterprise.Platform.Seeder.seed_tenant(opts)

      Mix.shell().info("""

      Provisioned tenant #{inspect(seeded.organization.name)}:

        organization    #{seeded.organization.id}
        business unit   #{seeded.business_unit.name} (#{seeded.business_unit.id})
        role            #{seeded.role.name}
        sign in as      #{seeded.user.email}
                        #{opts[:password] || "password1234"}

      Then visit http://localhost:4000/admin
      """)
    end
  end
end
