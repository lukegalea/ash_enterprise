defmodule Mix.Tasks.AshEnterprise.Backup.DrillTest do
  # Dumps and restores the test database, so it needs pg_dump and pg_restore no older than
  # the server and a role that can create databases: CI's `integration` job runs it
  # (`mix test --only backup_drill`). It does not use the sandbox: the drill opens its own
  # connections, as an operator's would.
  use ExUnit.Case, async: false

  alias Mix.Tasks.AshEnterprise.Backup.Drill

  @moduletag :backup_drill
  @moduletag timeout: 600_000

  defp source_versions do
    config = AshEnterprise.Repo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname] || "localhost",
        port: config[:port] || 5432,
        username: config[:username],
        password: config[:password],
        database: config[:database]
      )

    %{rows: rows} =
      Postgrex.query!(conn, "SELECT version FROM public.schema_migrations ORDER BY 1", [])

    GenServer.stop(conn)
    List.flatten(rows)
  end

  test "--rollback-to on a version that is not applied is refused, and the live database is untouched" do
    before = source_versions()

    assert_raise Mix.Error, ~r/not an applied migration/, fn ->
      Drill.drill(rollback_to: "19990101000000")
    end

    assert source_versions() == before
  end

  test "--rollback-to on the restored copy rolls back and re-applies, and the live database's schema_migrations is untouched" do
    before = source_versions()

    report = Drill.drill(rollback_to: "latest")

    assert report.status == "ok"
    assert report.rollback.to in before
    assert report.rollback.rolled_back == 1
    assert report.rollback.replayed == 1
    assert report.rollback.mismatches == []
    refute Map.get(report, :source_migrations_changed)
    assert source_versions() == before
  end
end
