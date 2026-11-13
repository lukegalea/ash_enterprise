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

  @release_copy Path.join(["priv", "compliance", "controls.json"])

  @doc """
  The control file every sweep reads: the configured path (`docs/controls.json`, relative to
  a source checkout) when it is there, otherwise the copy a release carries in its priv
  (`copy_control_file/1` in `mix.exs`). A release runs from its own root, which has no docs
  directory, so the configured path alone would leave every criterion `unknown` with
  `control_file_missing`.
  """
  @spec controls_file() :: Path.t()
  def controls_file do
    config()
    |> Keyword.get(:controls_file, "docs/controls.json")
    |> resolve(Application.app_dir(:ash_enterprise, @release_copy))
  end

  @doc false
  @spec resolve(Path.t(), Path.t()) :: Path.t()
  def resolve(configured, release_copy) do
    cond do
      File.regular?(configured) -> configured
      File.regular?(release_copy) -> release_copy
      true -> configured
    end
  end

  @doc "The criteria categories in the audit."
  def categories, do: Keyword.get(config(), :categories, [:security, :availability])

  defp config, do: Application.get_env(:ash_enterprise, __MODULE__, [])
end
