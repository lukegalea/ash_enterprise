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

  **Verified before anything is deleted.** Each move runs in one transaction: copy the rows,
  then compare the copy with the hot rows (the same count on both sides, every column equal,
  the same SHA-256 digest over their hashes in order, and for evidence every stored
  `content` hashing to its `hash`). Only when all of that holds are the hot rows deleted, and
  only if the delete removes exactly the rows that were verified. A failed comparison rolls
  the transaction back, so nothing is copied and nothing is deleted, and a `:failed`
  `AshEnterprise.Audit.ArchiveRun` records why. The database checks it a second time: the
  audit log's trigger refuses a `DELETE` of any row that has no identical archived copy, or
  is younger than ninety days.

  **Never purged before four hundred days.** `purge/1` deletes from the archive only when a
  deployment configures `purge_after_days`, which defaults to `nil` (never), and refuses a
  value under 400. The archive tables' triggers refuse to delete a row younger than 400 days
  whatever the configuration says. A purge of the audit archive records the hash of the last
  purged event, and `AshEnterprise.Audit.Chain` verifies what remains from that anchor.

  What stays hot regardless of age:

    * the **tail of each audit chain**, so the chain trigger always finds the row the next
      event links to;
    * the **newest evidence artifact** of each organization, control and collector, because
      the freshness sweep reads the hot table, and an annual control's one artifact must not
      read as missing because it is a hundred days old.

  An audit chain with a verification finding is not archived at all: a break is evidence,
  and it stays where the verifier first found it.

  ## Why this module writes SQL

  The audit log has no write actions (ash_events appends to it, and its triggers refuse
  everything else), and neither archive table has any. Moving a run of rows is a set-based
  copy and delete between tables the application never writes row by row, checked by
  triggers in the database. That is the "named infrastructure module for an SQL-only
  feature" case of the Ash discipline: it reads and writes no business row, and what it
  records about itself goes through Ash (`ArchiveRun`).

  The SQL is built from table names and tenant clauses fixed in this module, never from
  input; every value is a bound parameter. That is why the functions that build it carry
  `sobelow_skip ["SQL.Query"]`.
  """

  alias AshEnterprise.Audit
  alias AshEnterprise.Audit.Chain
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo

  @hot_floor_days 90
  @purge_floor_days 400
  @default_batch 10_000

  @event_columns ~w(id sequence organization_id record_id version occurred_at resource action
                    action_type user_id data changed_attributes metadata as_of as_of_range
                    previous_hash hash)

  @evidence_columns ~w(id organization_id control_id subject_type subject_id hash content
                       media_type collector method chain_of_custody retention_class
                       collected_at inserted_at)

  @doc "The fewest days anything stays hot. `hot_days` below it is refused."
  def hot_floor_days, do: @hot_floor_days

  @doc "The fewest days anything is kept at all. `purge_after_days` below it is refused."
  def purge_floor_days, do: @purge_floor_days

  @doc "The configured hot window, in days."
  @spec hot_days() :: pos_integer()
  def hot_days, do: Keyword.get(config(), :hot_days, @hot_floor_days)

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

    if days < @hot_floor_days do
      {:error, {:below_floor, :hot_days, @hot_floor_days}}
    else
      cutoff = DateTime.add(now, -days * 86_400, :second)

      audit = Enum.map(chains("audit_events"), &archive_chain(&1, cutoff, now, batch))
      {:ok, %{audit: audit, evidence: archive_evidence(cutoff, now, batch)}}
    end
  end

  defp archive_chain(org, cutoff, now, batch) do
    case Chain.verify(org) do
      %{findings: []} ->
        case boundary("audit_events", org, cutoff, batch, keep_tail?: true) do
          nil -> :nothing
          range -> move_chain(org, range, cutoff, now)
        end

      %{findings: findings} ->
        fail(%{
          store: :audit_events,
          kind: :archive,
          chain_organization_id: org,
          cutoff: cutoff,
          row_count: 0,
          reason: "the chain has #{length(findings)} verification finding(s); nothing was moved"
        })
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp move_chain(org, {from, to, count}, cutoff, now) do
    cols = Enum.join(@event_columns, ", ")
    params = [dump(org), from, to]

    result =
      Repo.transaction(fn ->
        Repo.query!(
          "INSERT INTO audit_event_archive (#{cols}, archived_at) " <>
            "SELECT #{cols}, $4 FROM audit_events " <>
            "WHERE #{tenant("organization_id")} AND sequence BETWEEN $2 AND $3 " <>
            "ON CONFLICT (id) DO NOTHING",
          params ++ [now]
        )

        with {:ok, digest} <- verify_event_copy(params, count),
             :ok <- delete_hot_events(params, count) do
          record!(%{
            store: :audit_events,
            kind: :archive,
            status: :verified,
            chain_organization_id: org,
            from_sequence: from,
            to_sequence: to,
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
        fail(move_failure(org, from, to, count, cutoff, reason))
    end
  rescue
    # The database refused (the immutability trigger, most likely): the transaction is
    # rolled back, so nothing was copied and nothing was deleted.
    error in Postgrex.Error ->
      fail(move_failure(org, from, to, count, cutoff, Exception.message(error)))
  end

  defp move_failure(org, from, to, count, cutoff, reason) do
    %{
      store: :audit_events,
      kind: :archive,
      chain_organization_id: org,
      from_sequence: from,
      to_sequence: to,
      row_count: count,
      cutoff: cutoff,
      reason: reason
    }
  end

  # The copy matches the hot rows: the same count on both sides of the range, every
  # column of every row equal, and the same digest over the hashes in order.
  # sobelow_skip ["SQL.Query"]
  defp verify_event_copy(params, count) do
    same_row =
      @event_columns
      |> Enum.map(&{"a.#{&1}", "h.#{&1}"})
      |> Enum.unzip()
      |> then(fn {a, h} ->
        "(#{Enum.join(a, ", ")}) IS NOT DISTINCT FROM (#{Enum.join(h, ", ")})"
      end)

    range = "BETWEEN $2 AND $3"

    %{rows: [[hot, archived, matching, hot_digest, archive_digest]]} =
      Repo.query!(
        """
        SELECT
          (SELECT count(*) FROM audit_events h
             WHERE #{tenant("h.organization_id")} AND h.sequence #{range}),
          (SELECT count(*) FROM audit_event_archive a
             WHERE #{tenant("a.organization_id")} AND a.sequence #{range}),
          (SELECT count(*) FROM audit_events h
             JOIN audit_event_archive a ON a.id = h.id AND #{same_row}
             WHERE #{tenant("h.organization_id")} AND h.sequence #{range}),
          (SELECT #{digest_sql("h")} FROM audit_events h
             WHERE #{tenant("h.organization_id")} AND h.sequence #{range}),
          (SELECT #{digest_sql("a")} FROM audit_event_archive a
             WHERE #{tenant("a.organization_id")} AND a.sequence #{range})
        """,
        params
      )

    cond do
      hot != count -> {:error, "hot rows changed under the move: #{hot} for #{count}"}
      archived != count -> {:error, "archive holds #{archived} rows for #{count} hot rows"}
      matching != count -> {:error, "#{count - matching} archived row(s) differ from the hot row"}
      hot_digest != archive_digest -> {:error, "digest mismatch"}
      true -> {:ok, hot_digest}
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp delete_hot_events(params, count) do
    %{num_rows: deleted} =
      Repo.query!(
        "DELETE FROM audit_events WHERE #{tenant("organization_id")} AND sequence BETWEEN $2 AND $3",
        params
      )

    if deleted == count, do: :ok, else: {:error, "deleted #{deleted} rows for #{count} verified"}
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

    case Keyword.get(opts, :days, purge_after_days()) do
      nil ->
        {:ok, :disabled}

      days when is_integer(days) and days >= @purge_floor_days ->
        cutoff = DateTime.add(now, -days * 86_400, :second)
        audit = Enum.map(chains("audit_event_archive"), &purge_chain(&1, cutoff, batch))
        {:ok, %{audit: audit, evidence: purge_evidence(cutoff, batch)}}

      _ ->
        {:error, {:below_floor, :purge_after_days, @purge_floor_days}}
    end
  end

  defp purge_chain(org, cutoff, batch) do
    case boundary("audit_event_archive", org, cutoff, batch, keep_tail?: false) do
      nil -> :nothing
      range -> purge_chain_range(org, range, cutoff)
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp purge_chain_range(org, {from, to, count}, cutoff) do
    params = [dump(org), from, to]

    result =
      Repo.transaction(fn ->
        %{rows: [[tail_hash, digest]]} =
          Repo.query!(
            """
            SELECT
              (SELECT hash FROM audit_event_archive
                 WHERE #{tenant("organization_id")} AND sequence = $3),
              (SELECT #{digest_sql("a")} FROM audit_event_archive a
                 WHERE #{tenant("a.organization_id")} AND a.sequence BETWEEN $2 AND $3)
            """,
            params
          )

        %{num_rows: deleted} =
          Repo.query!(
            "DELETE FROM audit_event_archive " <>
              "WHERE #{tenant("organization_id")} AND sequence BETWEEN $2 AND $3",
            params
          )

        if deleted != count, do: Repo.rollback("deleted #{deleted} rows for #{count}")

        record!(%{
          store: :audit_events,
          kind: :purge,
          status: :verified,
          chain_organization_id: org,
          from_sequence: from,
          to_sequence: to,
          row_count: count,
          digest: digest,
          tail_hash: tail_hash,
          cutoff: cutoff
        })
      end)

    case result do
      {:ok, run} -> {:purged, run}
      {:error, reason} -> fail(purge_failure(org, from, to, count, cutoff, reason))
    end
  rescue
    error in Postgrex.Error ->
      fail(purge_failure(org, from, to, count, cutoff, Exception.message(error)))
  end

  defp purge_failure(org, from, to, count, cutoff, reason) do
    %{
      store: :audit_events,
      kind: :purge,
      chain_organization_id: org,
      from_sequence: from,
      to_sequence: to,
      row_count: count,
      cutoff: cutoff,
      reason: reason
    }
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

  # Every chain in a table: one per tenant, plus the chain with no tenant.
  # sobelow_skip ["SQL.Query"]
  defp chains(table) do
    %{rows: rows} =
      Repo.query!("SELECT DISTINCT organization_id FROM #{table} ORDER BY 1 NULLS FIRST")

    Enum.map(rows, fn [org] -> org && Ecto.UUID.cast!(org) end)
  end

  # The leading run of a chain older than the cutoff, at most `batch` rows: every row below
  # the first one at or after the cutoff. In the hot log the chain's last row stays, so the
  # chain trigger always has a row to link the next event to.
  # sobelow_skip ["SQL.Query"]
  defp boundary(table, org, cutoff, batch, keep_tail?: keep_tail?) do
    tail_clause = if keep_tail?, do: "AND sequence < (SELECT max(sequence) FROM chain)", else: ""

    %{rows: [[from, to, count]]} =
      Repo.query!(
        """
        WITH chain AS (
          SELECT sequence, occurred_at FROM #{table} WHERE #{tenant("organization_id")}
        ),
        eligible AS (
          SELECT sequence FROM chain
          WHERE occurred_at < $2
            AND sequence < coalesce(
              (SELECT min(sequence) FROM chain WHERE occurred_at >= $2), 9223372036854775807)
            #{tail_clause}
          ORDER BY sequence
          LIMIT $3
        )
        SELECT min(sequence), max(sequence), count(*) FROM eligible
        """,
        [dump(org), cutoff, batch]
      )

    if count == 0, do: nil, else: {from, to, count}
  end

  # One filter for both kinds of chain, always on `$1`: a tenant's chain by equality, and the
  # chain with no tenant by `IS NULL` (with `$1` null), so each can use the chain index.
  defp tenant(column),
    do: "((#{column} = $1::uuid) OR ($1::uuid IS NULL AND #{column} IS NULL))"

  defp digest_sql(alias),
    do:
      "encode(sha256(convert_to(coalesce(string_agg(coalesce(#{alias}.hash, '-'), '|' " <>
        "ORDER BY #{alias}.sequence), ''), 'UTF8')), 'hex')"

  defp dump(nil), do: nil
  defp dump(org), do: Ecto.UUID.dump!(org)

  defp record!(attrs), do: Audit.record_archive_run!(attrs, actor: SystemActor.oban())

  defp fail(attrs) do
    reason = attrs |> Map.get(:reason) |> to_reason()
    {:failed, record!(Map.merge(attrs, %{status: :failed, reason: reason}))}
  end

  defp to_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp to_reason(reason), do: reason |> inspect() |> String.slice(0, 500)
end
