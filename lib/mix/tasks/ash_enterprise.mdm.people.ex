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

  `--seed-as EMAIL` first turns the sweep on for the organization, as that
  person, who must be a member of it (their business unit is one of its): it ensures
  the platform baselines a pair is routed by (`AshEnterprise.Mdm.Baselines`:
  the seed band table and the steward-review process), then drafts the people
  mapping and match rule set and activates them as that person (activation is
  person-gated, ADR 0054). Idempotent, like the sweep.

  Prints one line per tenant: counts (`observed`, `landed`, `staged`, and how
  many staged people were `created`, `merged`, sent to `review`, left
  `matched` or `omitted`), or `busy` when the application's own sweep of the
  tenant is running (one sweep per tenant at a time). Never a name or an
  address.
  """

  use Mix.Task

  require Ash.Query

  alias AshEnterprise.Mdm.People.{Pipeline, Seed, SweepWorker}
  alias AshEnterprise.Security.ActorContext

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
      # Membership first: a refused person changes nothing, baselines included.
      person = person!(organization, email)
      baselines = AshEnterprise.Mdm.Baselines.ensure!()
      Mix.shell().info("baselines #{inspect(baselines)}")
      Seed.seed!(organization, person)
      Mix.shell().info("people sweep turned on for #{organization}")
    end

    tenants = if opts[:organization], do: [opts[:organization]], else: SweepWorker.tenants()

    for tenant <- tenants do
      case Pipeline.run(tenant) do
        {:ok, :not_configured} ->
          Mix.shell().info("people #{tenant} not configured (pass --seed-as to turn it on)")

        {:ok, :busy} ->
          Mix.shell().info("people #{tenant} busy (another sweep of it is running; nothing done)")

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
    case seeder(organization, email) do
      {:ok, actor} -> actor
      {:error, :no_user} -> Mix.raise("no user with that email")
      {:error, :not_a_member} -> Mix.raise("that user is not a member of #{organization}")
    end
  end

  @doc """
  The person `--seed-as EMAIL` names, with their context attached, when they are
  a member of `organization`: their context was built for that tenant (it
  resolves through the business unit that owns them). A user is not
  tenant-scoped, so finding one by email says nothing about which tenant they
  belong to; this is the membership check.
  """
  @spec seeder(String.t(), String.t()) ::
          {:ok, ActorContext.actor()} | {:error, :no_user | :not_a_member}
  def seeder(organization, email) do
    AshEnterprise.Accounts.User
    |> Ash.Query.filter(email == ^email)
    # Looking the person up is not acting as them: who they are has to be known
    # before any of their authority can be.
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        {:error, :no_user}

      user ->
        context = ActorContext.build(user)

        if member?(context, organization),
          do: {:ok, ActorContext.attach(user, context)},
          else: {:error, :not_a_member}
    end
  end

  defp member?(%{organization_id: nil}, _organization), do: false

  defp member?(%{organization_id: organization_id}, organization),
    do: to_string(organization_id) == to_string(organization)
end
