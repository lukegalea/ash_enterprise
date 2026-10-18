defmodule AshEnterprise.Mdm.People.SweepWorker do
  @moduledoc """
  The people sweep's driver (PROD-9), on the `:mdm` queue like the import
  batches: newly projected people feed into MDM without anyone uploading
  anything.

    * **No `tenant` arg** (the cron tick): one job per tenant that turned the
      sweep on — has an active people rule set
      (`AshEnterprise.Mdm.People.Seed`).
    * **`%{"tenant" => id}`**: runs `AshEnterprise.Mdm.People.Pipeline.run/1`
      for that tenant.

  Idempotent (iron law #07): the job is unique per tenant while one is
  queued or running, a sweep the mix task is running for the tenant makes
  the job a no-op (the pipeline's per-tenant lock), and a run over unchanged
  people lands, stages and asks nothing (see the pipeline's moduledoc). Args are string-keyed ids only
  (iron laws #08, #09). Logs carry counts, never names or addresses.
  """

  use Oban.Worker,
    queue: :mdm,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:tenant],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Ash.Query
  require Logger

  alias AshEnterprise.Mdm.{MatchRuleSet, People}
  alias AshEnterprise.Mdm.People.Pipeline

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant" => tenant}}) when is_binary(tenant) do
    case Pipeline.run(tenant) do
      {:ok, :not_configured} ->
        :ok

      # A `mix ash_enterprise.mdm.people` run holds the tenant's sweep; the
      # next tick sees whatever it did not.
      {:ok, :busy} ->
        Logger.info("mdm people sweep skipped: another sweep of the tenant is running")
        :ok

      {:ok, counts} ->
        Logger.info("mdm people sweep #{format(counts)}")
        :ok
    end
  end

  def perform(%Oban.Job{}) do
    tenants()
    |> Enum.map(&new(%{"tenant" => &1}))
    |> Oban.insert_all()

    :ok
  end

  @doc "The tenants with the sweep turned on."
  def tenants do
    MatchRuleSet
    |> Ash.Query.filter(golden_resource == ^People.rule_set_key() and status == :active)
    |> Ash.Query.select([:organization_id])
    |> Ash.read!(tenant: nil, authorize?: false)
    |> Enum.map(& &1.organization_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "A counts map as one log/console line."
  def format(counts) when is_map(counts) do
    counts
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
  end
end
