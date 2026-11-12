defmodule AshEnterprise.Compliance.FreshnessSweepWorker do
  @moduledoc """
  Runs `ash_compliance`'s freshness sweep for every organization, hourly (the crontab in
  `config/config.exs`).

  `AshCompliance.Ownership.Sweep` reads the control file, the evidence and the waivers of one
  organization: each in-scope criterion whose evidence is missing or stale, or whose operating
  process is overdue, becomes a `Finding` with status `:unknown` under the subject
  `evidence_freshness`, and a finding whose evidence is established again is resolved. It
  reports and never blocks.

      config :ash_enterprise, AshEnterprise.Compliance.FreshnessSweepWorker,
        controls_file: "docs/controls.json",
        categories: [:security, :availability]

  ## Why not the library's worker

  `ash_compliance` ships `AshCompliance.Workers.EvidenceFreshness` for this, but compiles it
  only when Oban is already loaded, and declares Oban as a dev and test dependency only. In a
  host, Oban is then not guaranteed to compile first, and here it does not: the worker module
  does not exist. This worker calls the same sweep (`docs/BLEEDING-EDGE.md`, section 3).

  The job fails, and Oban retries it, only when a sweep could not run; every organization is
  swept either way, and the error names the ones that failed.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 300]

  alias AshCompliance.Ownership.Sweep

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Trusted machinery reading the tenant list, not a person's request.
    organizations =
      AshEnterprise.Accounts.list_organizations!(authorize?: false) |> Enum.map(& &1.id)

    results = Enum.map(organizations, &{&1, sweep(&1)})

    case for({org, {:error, error}} <- results, do: {org, error}) do
      [] -> {:ok, length(organizations)}
      errors -> {:error, errors}
    end
  end

  @doc """
  Sweeps one organization. Options: `:now`. Returns what `AshCompliance.Ownership.Sweep.run/2`
  returns.
  """
  @spec sweep(Ash.UUID.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def sweep(organization_id, opts \\ []) do
    Sweep.run(
      organization_id,
      Keyword.merge([controls_file: controls_file(), categories: categories()], opts)
    )
  end

  @doc "The control file every sweep reads."
  def controls_file, do: Keyword.get(config(), :controls_file, "docs/controls.json")

  @doc "The criteria categories in the audit."
  def categories, do: Keyword.get(config(), :categories, [:security, :availability])

  defp config, do: Application.get_env(:ash_enterprise, __MODULE__, [])
end
