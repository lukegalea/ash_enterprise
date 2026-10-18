defmodule Mix.Tasks.AshEnterprise.Mdm.People do
  @shortdoc "Resolves the same person across Gmail, Calendar and Slack now (counts only)"

  @moduledoc """
  Runs the MDM people sweep on demand (PROD-9, `AshEnterprise.Mdm.People`):
  observes the people the projectors produced, lands and stages what is new,
  and matches it — exact addresses join their golden record, likely
  duplicates go to the steward queue (`/app/mdm`).

      mix ash_enterprise.mdm.people                                  # every tenant that turned it on
      mix ash_enterprise.mdm.people --organization <id>
      mix ash_enterprise.mdm.people --organization <id> --seed-as admin@example.com

  `--seed-as EMAIL` first turns the sweep on for the organization: it drafts
  the people mapping and match rule set and activates them as that person
  (activation is person-gated, ADR 0054). Idempotent, like the sweep.

  Prints one line per tenant: counts (`observed`, `landed`, `staged`, and how
  many staged people were `created`, `merged`, sent to `review`, left
  `matched` or `omitted`). Never a name or an address.
  """

  use Mix.Task

  require Ash.Query

  alias AshEnterprise.Mdm.People.{Pipeline, Seed, SweepWorker}

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv, strict: [organization: :string, seed_as: :string])

    # Repo only, plus an Oban instance that inserts and runs nothing (iron
    # law #23): a review-banded pair starts the `mdm.steward_review`
    # process, whose first step is a job the running application executes.
    AshEnterprise.Mix.Helpers.boot_repo()
    AshEnterprise.Mix.Helpers.load_domain_resources()
    start_insert_only_oban()

    if email = opts[:seed_as] do
      organization = opts[:organization] || Mix.raise("--seed-as needs --organization <id>")
      Seed.seed!(organization, person!(organization, email))
      Mix.shell().info("people sweep turned on for #{organization}")
    end

    tenants = if opts[:organization], do: [opts[:organization]], else: SweepWorker.tenants()

    for tenant <- tenants do
      case Pipeline.run(tenant) do
        {:ok, :not_configured} ->
          Mix.shell().info("people #{tenant} not configured (pass --seed-as to turn it on)")

        {:ok, counts} ->
          Mix.shell().info("people #{tenant} #{SweepWorker.format(counts)}")
      end
    end
  end

  defp start_insert_only_oban do
    {:ok, _} = Application.ensure_all_started(:oban)

    config =
      :ash_enterprise
      |> Application.get_env(Oban, [])
      |> Keyword.merge(queues: false, plugins: false, peer: false)

    case Oban.start_link(config) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp person!(organization, email) do
    AshEnterprise.Accounts.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(tenant: organization, authorize?: false)
    |> case do
      nil -> Mix.raise("no user with that email in #{organization}")
      user -> user
    end
  end
end
