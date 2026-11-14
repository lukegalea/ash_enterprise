defmodule AshEnterprise.Audit.RetentionWorker do
  @moduledoc """
  Runs the retention policy once a day (`AshEnterprise.Audit.Retention`; the crontab in
  `config/config.exs`): archive what is past the ninety-day hot window, then purge from the
  archive what is past `purge_after_days`, which is never unless a deployment configures it.

  Idempotent: a second run the same day finds nothing to move. A move that does not verify
  deletes nothing and is recorded as a failed `AshEnterprise.Audit.ArchiveRun`; the job still
  succeeds, because retrying an archive that refused would refuse again, and the failed run is
  the record someone reads.

  **A backlog is reported, not alarmed on.** When more audit events are eligible than one run
  may move (`max_batches` batches of `batch_size` per chain, within `deadline_ms`), the rest
  waits for the next run. The job's result carries the count as `backlog`, the
  `[:ash_enterprise, :audit, :retention]` telemetry event carries it as a measurement (the
  `ash_enterprise.audit.retention.backlog` metric), each chain's last run says so in its
  `reason`, and a non-zero backlog logs a warning.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias AshEnterprise.Audit.Retention

  @event [:ash_enterprise, :audit, :retention]

  @doc "The telemetry event each run emits."
  def event, do: @event

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run()

  @doc """
  Archives, then purges. Options are passed to both (`AshEnterprise.Audit.Retention`).
  Returns `{:ok, %{archived: counts, purged: counts, backlog: %{archive: n, purge: n}}}`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, archived} <- Retention.archive(opts),
         {:ok, purged} <- Retention.purge(opts) do
      backlog = %{archive: Retention.backlog(archived), purge: Retention.backlog(purged)}
      report(archived, backlog)
      {:ok, %{archived: summary(archived), purged: summary(purged), backlog: backlog}}
    end
  end

  defp report(archived, backlog) do
    failed = archived |> steps() |> Enum.count(&match?({:failed, _}, &1))

    :telemetry.execute(
      @event,
      %{backlog: backlog.archive, purge_backlog: backlog.purge, failed: failed},
      %{}
    )

    if backlog.archive > 0 do
      Logger.warning(
        "Audit retention left #{backlog.archive} event(s) past the hot window for the next " <>
          "run: more were eligible than one run may move."
      )
    end
  end

  defp steps(%{audit: audit, evidence: evidence}), do: [evidence | audit]

  defp summary(:disabled), do: :disabled

  defp summary(result), do: result |> steps() |> Enum.frequencies_by(&step/1)

  defp step({kind, _run}), do: kind
  defp step(kind), do: kind
end
