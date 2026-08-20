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
      # The legacy estate first, so the greenfield tenant is provably not the
      # only one and the isolation claim in plan §4.2 has something to isolate
      # from. Idempotent, unlike the greenfield half.
      case AshEnterprise.Platform.Seeder.seed_legacy_estate() do
        :already_seeded ->
          Mix.shell().info("Legacy estate already provisioned.")

        seeded ->
          Mix.shell().info(
            "Provisioned the legacy estate tenant #{inspect(seeded.organization.name)} " <>
              "(sign in as #{seeded.user.email})."
          )
      end

      seeded = AshEnterprise.Platform.Seeder.seed_tenant(opts)

      # Project the legacy estate into `projected_users`, and do it *here* rather than in a mix
      # alias, because this is the only point at which all three of its prerequisites exist: the
      # migrations have created the table, `seed_privileges/0` above has put the new resource in
      # the privilege catalogue, and `seed_legacy_estate/0` has created the Organization the
      # projected rows are tenant-scoped to.
      #
      # Wired into `mix ash_enterprise.legacy.setup` first, which looks like the obvious home and
      # is the one place it cannot go: that task has to run *before* the migrations, because the
      # strangler view it creates needs `legacy.users` to exist. The result was nine
      # `relation "projected_users" does not exist` failures reported as refused rows -- a
      # structural mistake wearing a data-quality finding's clothes.
      Mix.Task.run("ash_enterprise.legacy.project")

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
