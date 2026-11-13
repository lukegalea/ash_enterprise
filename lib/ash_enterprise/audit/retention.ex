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
  verifies what remains from that anchor. This module passes it this application's
  configuration and the `oban` system actor its run ledger (`AshEnterprise.Audit.ArchiveRun`)
  allows.

  **Evidence is this module's.** Each move runs in one transaction: copy the rows, then
  compare the copy with the hot rows (the same count on both sides, every column equal, the
  same SHA-256 digest over their hashes in order, and every stored `content` hashing to its
  `hash`). Only when all of that holds are the hot rows deleted, and only if the delete
  removes exactly the rows that were verified. A failed comparison rolls the transaction
  back, so nothing is copied and nothing is deleted, and a `:failed`
  `AshEnterprise.Audit.ArchiveRun` records why. The newest evidence artifact of each
  organization, control and collector stays hot regardless of age, because the freshness
  sweep reads the hot table, and an annual control's one artifact must not read as missing
  because it is a hundred days old.

  **Never purged before four hundred days.** `purge/1` deletes from the archive only when a
  deployment configures `purge_after_days`, which defaults to `nil` (never), and refuses a
  value under 400. The archive tables' triggers refuse to delete a row younger than 400 days
  whatever the configuration says.

  ## Why this module writes SQL

  Neither the evidence table's archive nor its move has a write action: moving a run of rows
  is a set-based copy and delete between tables the application never writes row by row,
  checked by triggers in the database. That is the "named infrastructure module for an
  SQL-only feature" case of the Ash discipline: it reads and writes no business row, and what
  it records about itself goes through Ash (`ArchiveRun`).

  The SQL is built from table names fixed in this module, never from input; every value is a
  bound parameter. That is why the functions that build it carry `sobelow_skip ["SQL.Query"]`.
  """

  alias AshEnterprise.Audit
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo
  alias AshEvents.Chain.SQL

  @default_batch 10_000

  @evidence_columns ~w(id organization_id control_id subject_type subject_id hash content
                       media_type collector method chain_of_custody retention_class
                       collected_at inserted_at)

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

  # --- archive ------------------------------------------------------------------

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
    batch = Keyword.get(opts, :batch_size, Keyword.get(config(), :batch_size, @default_batch))

    with {:ok, audit} <-
           AshEvents.Chain.Retention.archive(EventLog,
             now: now,
             hot_days: days,
             batch_size: batch,
             actor: SystemActor.oban()
           ) do
      cutoff = DateTime.add(now, -days * 86_400, :second)
      {:ok, %{audit: audit, evidence: archive_evidence(cutoff, now, batch)}}
    end
  end

  # --- evidence -------------------------------------------------------------------

  # sobelow_skip ["SQL.Query"]
  defp archive_evidence(cutoff, now, batch) do
    table = evidence_table()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT e.id FROM #{table} e
        WHERE e.collected_at < $1
          AND EXISTS (
            SELECT 1 FROM #{table} n
            WHERE n.organization_id = e.organization_id
              AND n.control_id = e.control_id
              AND n.collector = e.collector
              AND (n.collected_at, n.id) > (e.collected_at, e.id))
        ORDER BY e.collected_at, e.id
        LIMIT $2
        """,
        [cutoff, batch]
      )

    case Enum.map(rows, fn [id] -> id end) do
      [] -> :nothing
      ids -> move_evidence(table, ids, cutoff, now)
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp move_evidence(table, ids, cutoff, now) do
    count = length(ids)
    cols = Enum.join(@evidence_columns, ", ")

    result =
      Repo.transaction(fn ->
        Repo.query!(
          "INSERT INTO evidence_artifact_archive (#{cols}, archived_at) " <>
            "SELECT #{cols}, $2 FROM #{table} WHERE id = ANY($1) ON CONFLICT (id) DO NOTHING",
          [ids, now]
        )

        with {:ok, digest} <- verify_evidence_copy(table, ids, count),
             :ok <- delete_hot_evidence(table, ids, count) do
          record!(%{
            store: :evidence_artifacts,
            kind: :archive,
            status: :verified,
            row_count: count,
            digest: digest,
            cutoff: cutoff
          })
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} ->
        {:archived, run}

      {:error, reason} ->
        fail(%{
          store: :evidence_artifacts,
          kind: :archive,
          row_count: count,
          cutoff: cutoff,
          reason: reason
        })
    end
  end

  defp evidence_same_row do
    @evidence_columns
    |> Enum.map(&{"a.#{&1}", "h.#{&1}"})
    |> Enum.unzip()
    |> then(fn {a, h} ->
      "(#{Enum.join(a, ", ")}) IS NOT DISTINCT FROM (#{Enum.join(h, ", ")})"
    end)
  end

  # sobelow_skip ["SQL.Query"]
  defp verify_evidence_copy(table, ids, count) do
    %{rows: [[hot, archived, matching, bad_content, hot_digest, archive_digest]]} =
      Repo.query!(
        """
        SELECT
          (SELECT count(*) FROM #{table} h WHERE h.id = ANY($1)),
          (SELECT count(*) FROM evidence_artifact_archive a WHERE a.id = ANY($1)),
          (SELECT count(*) FROM #{table} h
             JOIN evidence_artifact_archive a ON a.id = h.id AND #{evidence_same_row()}
             WHERE h.id = ANY($1)),
          (SELECT count(*) FROM evidence_artifact_archive a
             WHERE a.id = ANY($1) AND a.content IS NOT NULL
               AND encode(sha256(a.content), 'hex') <> a.hash),
          (SELECT encode(sha256(convert_to(coalesce(string_agg(h.hash, '|' ORDER BY h.id), ''), 'UTF8')), 'hex')
             FROM #{table} h WHERE h.id = ANY($1)),
          (SELECT encode(sha256(convert_to(coalesce(string_agg(a.hash, '|' ORDER BY a.id), ''), 'UTF8')), 'hex')
             FROM evidence_artifact_archive a WHERE a.id = ANY($1))
        """,
        [ids]
      )

    cond do
      hot != count ->
        {:error, "hot artifacts changed under the move: #{hot} for #{count}"}

      archived != count ->
        {:error, "archive holds #{archived} artifacts for #{count}"}

      matching != count ->
        {:error, "#{count - matching} archived artifact(s) differ from the hot row"}

      bad_content > 0 ->
        {:error, "#{bad_content} archived artifact(s) do not hash to their hash"}

      hot_digest != archive_digest ->
        {:error, "digest mismatch"}

      true ->
        {:ok, hot_digest}
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp delete_hot_evidence(table, ids, count) do
    %{num_rows: deleted} =
      Repo.query!(
        """
        DELETE FROM #{table} h
        WHERE h.id = ANY($1)
          AND EXISTS (SELECT 1 FROM evidence_artifact_archive a
                      WHERE a.id = h.id AND #{evidence_same_row()})
        """,
        [ids]
      )

    if deleted == count,
      do: :ok,
      else: {:error, "deleted #{deleted} artifacts for #{count} verified"}
  end

  defp evidence_table,
    do: AshPostgres.DataLayer.Info.table(AshCompliance.Resources.EvidenceArtifact)

  # --- purge ------------------------------------------------------------------------

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
    batch = Keyword.get(opts, :batch_size, Keyword.get(config(), :batch_size, @default_batch))
    days = Keyword.get(opts, :days, purge_after_days())

    case AshEvents.Chain.Retention.purge(EventLog,
           now: now,
           purge_after_days: days,
           batch_size: batch,
           actor: SystemActor.oban()
         ) do
      {:ok, :disabled} ->
        {:ok, :disabled}

      {:ok, audit} ->
        cutoff = DateTime.add(now, -days * 86_400, :second)
        {:ok, %{audit: audit, evidence: purge_evidence(cutoff, batch)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp purge_evidence(cutoff, batch) do
    result =
      Repo.transaction(fn ->
        %{num_rows: deleted} =
          Repo.query!(
            """
            DELETE FROM evidence_artifact_archive
            WHERE id IN (SELECT id FROM evidence_artifact_archive
                         WHERE collected_at < $1 ORDER BY collected_at, id LIMIT $2)
            """,
            [cutoff, batch]
          )

        if deleted > 0 do
          record!(%{
            store: :evidence_artifacts,
            kind: :purge,
            status: :verified,
            row_count: deleted,
            cutoff: cutoff
          })
        end
      end)

    case result do
      {:ok, nil} -> :nothing
      {:ok, run} -> {:purged, run}
    end
  rescue
    error in Postgrex.Error ->
      fail(%{
        store: :evidence_artifacts,
        kind: :purge,
        row_count: 0,
        cutoff: cutoff,
        reason: Exception.message(error)
      })
  end

  # --- shared ---------------------------------------------------------------------

  defp record!(attrs), do: Audit.record_archive_run!(attrs, actor: SystemActor.oban())

  defp fail(attrs) do
    reason = attrs |> Map.get(:reason) |> to_reason()
    {:failed, record!(Map.merge(attrs, %{status: :failed, reason: reason}))}
  end

  defp to_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp to_reason(reason), do: reason |> inspect() |> String.slice(0, 500)
end
