defmodule AshEnterprise.Audit.Retention do
  @moduledoc """
  How long evidence is kept, and where it lives after ninety days (ADR 0024's age half).

      config :ash_enterprise, AshEnterprise.Audit.Retention,
        hot_days: 90,
        purge_after_days: nil,
        batch_size: 10_000

  **Ninety days hot.** Audit events (`audit_events`) and evidence artifacts
  (`AshCompliance.Resources.EvidenceArtifact`) older than `hot_days` move to the archive
  store, `AshEnterprise.Audit.ArchivedEvent` and `AshEnterprise.Audit.ArchivedEvidence`,
  tables in the same database. `archive/1` runs daily (`AshEnterprise.Audit.RetentionWorker`).

  **The audit log's move is `ash_events_chain`'s** (`AshEvents.Chain.Retention`): each tenant
  chain is verified first, a chain with a finding is not moved, the tail of every chain stays
  hot, and a purge records the hash of the last purged event so `AshEvents.Chain.verify/2`
  verifies what remains from that anchor.

  **Evidence's move is `ash_compliance`'s** (`AshCompliance.Ownership.Retention`): each batch
  is copied, compared with the hot rows column by column and by hash, and only then deleted
  from the hot table, in one transaction. The newest evidence artifact of each organization,
  control and collector stays hot regardless of age, and every read of evidence for a period
  takes the hot table and the archive together, so a move never changes what the freshness
  sweep finds.

  This module passes both this application's configuration, its run ledger
  (`AshEnterprise.Audit.ArchiveRun`) and the `oban` system actor that ledger allows. A failed
  comparison deletes nothing and is recorded as a `:failed` run.

  **Never purged before four hundred days.** `purge/1` deletes from the archive only when a
  deployment configures `purge_after_days`, which defaults to `nil` (never), and refuses a
  value under 400. The archive tables' triggers refuse to delete a row younger than 400 days
  whatever the configuration says.
  """

  alias AshCompliance.Ownership.Retention, as: EvidenceRetention
  alias AshEnterprise.Audit.{ArchiveRun, EventLog}
  alias AshEnterprise.Platform.SystemActor
  alias AshEvents.Chain.SQL

  @default_batch 10_000

  @doc "The fewest days anything stays hot. `hot_days` below it is refused."
  def hot_floor_days, do: SQL.hot_floor_days()

  @doc "The fewest days anything is kept at all. `purge_after_days` below it is refused."
  def purge_floor_days, do: SQL.purge_floor_days()

  @doc "The configured hot window, in days."
  @spec hot_days() :: pos_integer()
  def hot_days, do: Keyword.get(config(), :hot_days, hot_floor_days())

  @doc "The configured purge age, in days, or `nil` for never."
  @spec purge_after_days() :: pos_integer() | nil
  def purge_after_days, do: Keyword.get(config(), :purge_after_days)

  defp config, do: Application.get_env(:ash_enterprise, __MODULE__, [])

  @doc """
  Moves everything past the hot window to the archive store, verifying each move first.

  Options: `:now`, `:hot_days` (at least 90), `:batch_size` (rows per chain or per evidence
  batch in one transaction). Returns `{:ok, %{audit: [step], evidence: step}}`, where each
  step is `:nothing`, `{:archived, run}` or `{:failed, run}`, or `{:error, reason}` when the
  window is below the floor.
  """
  @spec archive(keyword()) :: {:ok, map()} | {:error, term()}
  def archive(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    days = Keyword.get(opts, :hot_days, hot_days())
    batch = batch_size(opts)

    with {:ok, audit} <-
           AshEvents.Chain.Retention.archive(EventLog,
             now: now,
             hot_days: days,
             batch_size: batch,
             actor: SystemActor.oban()
           ),
         {:ok, evidence} <-
           EvidenceRetention.archive([now: now, hot_days: days, batch_size: batch] ++ ledger()) do
      {:ok, %{audit: audit, evidence: evidence}}
    end
  end

  @doc """
  Deletes from the archive store what is older than `purge_after_days`.

  Never runs unless a number is configured or passed as `:days`, and refuses one under 400.
  The archive tables' triggers refuse a younger row anyway. Options: `:now`, `:days`,
  `:batch_size`. Returns `{:ok, :disabled}`, `{:ok, %{audit: [step], evidence: step}}` or
  `{:error, reason}`.
  """
  @spec purge(keyword()) :: {:ok, :disabled | map()} | {:error, term()}
  def purge(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    batch = batch_size(opts)
    days = Keyword.get(opts, :days, purge_after_days())

    with {:ok, audit} when audit != :disabled <-
           AshEvents.Chain.Retention.purge(EventLog,
             now: now,
             purge_after_days: days,
             batch_size: batch,
             actor: SystemActor.oban()
           ),
         {:ok, evidence} <-
           EvidenceRetention.purge(
             [now: now, purge_after_days: days, batch_size: batch] ++ ledger()
           ) do
      {:ok, %{audit: audit, evidence: evidence}}
    end
  end

  defp batch_size(opts),
    do: Keyword.get(opts, :batch_size, Keyword.get(config(), :batch_size, @default_batch))

  # The archive is `config :ash_compliance, evidence_archive:`; each step is recorded in the
  # run ledger the audit log's moves are recorded in, by the actor it allows.
  defp ledger, do: [archive_run: ArchiveRun, actor: SystemActor.oban()]
end
