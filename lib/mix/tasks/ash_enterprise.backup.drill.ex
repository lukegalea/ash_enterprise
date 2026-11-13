defmodule Mix.Tasks.AshEnterprise.Backup.Drill do
  @shortdoc "Backs the database up, restores it into a fresh database, and proves the copy"

  @moduledoc """
  A backup and restore drill (q48): dump the configured database, restore the dump into a
  fresh database, and check the copy before calling the backup good.

      mix ash_enterprise.backup.drill
      mix ash_enterprise.backup.drill --keep --dump /backups/drill.dump --json drill.json

  `scripts/backup-restore-drill` runs it; `docs/runbooks/backup-and-restore.md` is the
  procedure around it.

  1. **Count, then dump, from one snapshot.** A `REPEATABLE READ` transaction exports its
     snapshot, counts the rows of every table in it, and `pg_dump -Fc --snapshot` dumps that
     same snapshot. The counts and the dump describe one instant, so the drill runs against
     a live database too.
  2. **Restore into a fresh database** (`<database>_restore_drill`, dropped first if a
     previous drill left it): `pg_restore --exit-on-error`.
  3. **Prove the copy.** Every table holds the same number of rows as the snapshot, and every
     audit chain in the copy verifies (`AshEvents.Chain.verify_all/1`, hot and
     archived rows), so the restore brought back the log intact, not only a log of the right
     length.
  4. **Report** the dump's size and SHA-256, how long the dump and the restore took, and
     what was checked. `--json PATH` also writes the report as JSON.

  Exits non-zero, keeping the restored database for inspection, when any count differs or a
  chain has a finding. Otherwise the restored database is dropped (`--keep` keeps it) and the
  dump is deleted unless `--dump PATH` names where to keep it.

  It needs `pg_dump` and `pg_restore` no older than the server, and a role that can create
  databases. It measures one restore of this database on this server: a recovery time for a
  deployment's own data, and its recovery point, come from running it there.
  """

  use Mix.Task

  alias AshEnterprise.Audit.EventLog

  @requirements ["app.config"]

  @switches [keep: :boolean, dump: :string, json: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    for app <- [:postgrex, :ecto_sql, :ash], do: {:ok, _} = Application.ensure_all_started(app)

    report = drill(opts)
    print(report)

    if json = opts[:json], do: File.write!(json, Jason.encode_to_iodata!(report, pretty: true))

    unless report.status == "ok", do: exit({:shutdown, 1})
  end

  @doc """
  Runs the drill and returns its report. Options: `:keep`, `:dump` (as the switches).
  """
  @spec drill(keyword()) :: map()
  def drill(opts \\ []) do
    conn = connection_opts()
    source = Keyword.fetch!(conn, :database)
    target = source <> "_restore_drill"
    path = opts[:dump] || Path.join(System.tmp_dir!(), "#{target}-#{System.os_time()}.dump")
    keep? = opts[:keep] == true

    {:ok, admin} = Postgrex.start_link(conn)

    {dump_ms, counts} = :timer.tc(fn -> dump_from_snapshot(admin, conn, path) end, :millisecond)

    Postgrex.query!(admin, ~s[DROP DATABASE IF EXISTS "#{target}" WITH (FORCE)], [])
    Postgrex.query!(admin, ~s[CREATE DATABASE "#{target}"], [])

    {restore_ms, :ok} = :timer.tc(fn -> restore(conn, target, path) end, :millisecond)

    {:ok, copy} = Postgrex.start_link(Keyword.put(conn, :database, target))
    restored = count_rows(copy)
    GenServer.stop(copy)

    {verify_ms, chains} = :timer.tc(fn -> verify_chains(target) end, :millisecond)

    checks = compare(counts, restored, chains)
    kept? = keep? or checks.status != "ok"

    unless kept?,
      do: Postgrex.query!(admin, ~s[DROP DATABASE IF EXISTS "#{target}" WITH (FORCE)], [])

    GenServer.stop(admin)

    Map.merge(checks, %{
      source: source,
      restored_into: target,
      restored_kept: kept?,
      dump: dump_report(path, opts[:dump]),
      timings_ms: %{dump: dump_ms, restore: restore_ms, verify: verify_ms}
    })
  end

  defp compare(counts, restored, chains) do
    mismatches =
      for {table, rows} <- counts, Map.get(restored, table) != rows do
        %{table: table, snapshot: rows, restored: Map.get(restored, table)}
      end

    extra = Map.keys(restored) -- Map.keys(counts)
    findings = Enum.flat_map(chains, & &1.findings)

    %{
      status: if(mismatches == [] and extra == [] and findings == [], do: "ok", else: "failed"),
      tables: map_size(counts),
      rows: counts |> Map.values() |> Enum.sum(),
      mismatches:
        mismatches ++ Enum.map(extra, &%{table: &1, snapshot: nil, restored: restored[&1]}),
      chains: length(chains),
      events_verified: chains |> Enum.map(& &1.checked) |> Enum.sum(),
      chain_findings: length(findings)
    }
  end

  # Size and SHA-256 of the dump; deleted afterwards unless the caller named where to keep it.
  defp dump_report(path, kept_at) do
    %{size: bytes} = File.stat!(path)
    sha256 = sha256_file(path)
    unless kept_at, do: File.rm!(path)
    %{path: kept_at, bytes: bytes, sha256: sha256}
  end

  # Counts every table and dumps, both inside one exported snapshot.
  defp dump_from_snapshot(admin, conn, path) do
    {:ok, counts} =
      Postgrex.transaction(
        admin,
        fn tx ->
          Postgrex.query!(tx, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
          %{rows: [[snapshot]]} = Postgrex.query!(tx, "SELECT pg_export_snapshot()", [])
          counts = count_rows(tx)

          pg!("pg_dump", [
            "--format=custom",
            "--snapshot=#{snapshot}",
            "--file=#{path}"
            | conn_args(conn, Keyword.fetch!(conn, :database))
          ])

          counts
        end,
        timeout: :infinity
      )

    counts
  end

  defp restore(conn, target, path) do
    pg!(
      "pg_restore",
      [
        "--exit-on-error",
        "--no-owner",
        "--no-acl",
        "--dbname=#{target}" | conn_args(conn, nil)
      ] ++ [path]
    )
  end

  # Exact counts of every user table, by schema-qualified name. The table list is read from
  # the catalogue, so a table the drill does not know about is still counted.
  defp count_rows(conn) do
    %{rows: tables} =
      Postgrex.query!(
        conn,
        """
        SELECT quote_ident(schemaname) || '.' || quote_ident(tablename)
        FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
          AND schemaname NOT LIKE 'pg_toast%'
        ORDER BY 1
        """,
        []
      )

    Map.new(tables, fn [table] ->
      %{rows: [[count]]} = Postgrex.query!(conn, "SELECT count(*) FROM #{table}", [])
      {table, count}
    end)
  end

  # The chain verifier, run against the copy: the application's repo, started on the restored
  # database for this process only.
  defp verify_chains(target) do
    {:ok, repo} =
      AshEnterprise.Repo.start_link(
        name: nil,
        database: target,
        pool: DBConnection.ConnectionPool,
        pool_size: 2,
        log: false
      )

    AshEnterprise.Repo.put_dynamic_repo(repo)

    try do
      AshEvents.Chain.verify_all(EventLog)
    after
      AshEnterprise.Repo.put_dynamic_repo(AshEnterprise.Repo)
      Supervisor.stop(repo)
    end
  end

  defp connection_opts do
    config = AshEnterprise.Repo.config()

    [
      hostname: config[:hostname] || "localhost",
      port: config[:port] || 5432,
      username: config[:username],
      password: config[:password],
      database: config[:database]
    ]
  end

  defp conn_args(conn, database) do
    ["--host=#{conn[:hostname]}", "--port=#{conn[:port]}", "--username=#{conn[:username]}"] ++
      if(database, do: [database], else: [])
  end

  defp pg!(command, args) do
    env = [{"PGPASSWORD", AshEnterprise.Repo.config()[:password] || ""}]

    case System.cmd(System.get_env(String.upcase(command), command), args,
           env: env,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, status} -> Mix.raise("#{command} exited #{status}:\n#{output}")
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp print(report) do
    Mix.shell().info("""
    Backup and restore drill: #{report.status}
      source            #{report.source}
      restored into     #{report.restored_into}#{if report.restored_kept, do: " (kept)", else: " (dropped)"}
      dump              #{report.dump.bytes} bytes, sha256 #{report.dump.sha256}
      dump took         #{report.timings_ms.dump} ms
      restore took      #{report.timings_ms.restore} ms
      tables, rows      #{report.tables} tables, #{report.rows} rows; #{length(report.mismatches)} count mismatch(es)
      audit chains      #{report.chains} chain(s), #{report.events_verified} event(s), #{report.chain_findings} finding(s)
    """)

    for m <- report.mismatches do
      Mix.shell().error(
        "  #{m.table}: #{m.snapshot} in the snapshot, #{inspect(m.restored)} restored"
      )
    end
  end
end
