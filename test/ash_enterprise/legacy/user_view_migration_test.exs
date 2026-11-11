defmodule AshEnterprise.Legacy.UserViewMigrationTest do
  @moduledoc """
  The migration that types the NULLs of `strangler.users` (20261109160000) goes down and up again
  without changing what it manages.

  Its `up` drops the view and creates it again, so everything a `DROP VIEW` takes with it has to
  come back: the view's shape, its table and column privileges, and the owner. Its `down` does the
  same in the other direction and restores the ledger function to what it was before. Nothing else
  exercises either direction: the suite starts from a database that was migrated up, so a `down`
  that does not run, or an `up` that loses a grant when it runs a second time, would otherwise be
  found by whoever next had to roll it back.

  This is the repository's one test of a migration's `down`. It uses `Ecto.Migrator` on the
  migration's own module, inside the sandbox's transaction: the DDL is transactional in
  Postgres, so the database is the same afterwards as it was before, and the test does not need a
  database of its own. That is also why it is not `async`: the `DROP VIEW` holds a lock on the view
  until the test's transaction ends.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Repo

  @version 20_261_109_160_000
  @migration_file "priv/repo/migrations/20261109160000_type_the_strangler_user_nulls.exs"
  @typed_nulls ~w(created_by_id modified_by_id created_on_behalf_by_id modified_on_behalf_by_id
                  overridden_created_on import_sequence_number)

  setup do
    migration = migration_module()

    %{rows: [[1]]} =
      Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [@version])

    suffix = System.unique_integer([:positive])
    reader = "view_migration_reader_#{suffix}"
    editor = "view_migration_editor_#{suffix}"

    # Roles are cluster-wide, but creating them in the sandbox's transaction means they roll back
    # with it. The grants cover each branch of what the migration saves: a table-level grant that is
    # grantable, and column-level grants of two privileges.
    Repo.query!(~s|CREATE ROLE "#{reader}"|)
    Repo.query!(~s|CREATE ROLE "#{editor}"|)
    Repo.query!(~s|GRANT SELECT ON strangler.users TO "#{reader}" WITH GRANT OPTION|)
    Repo.query!(~s|GRANT SELECT (login, email), UPDATE (login) ON strangler.users TO "#{editor}"|)

    %{migration: migration}
  end

  test "up, down and up again leave the view, the ledger function and the privileges as they were",
       %{migration: migration} do
    before = snapshot()

    run!(migration, :down)
    down = snapshot()

    # The down really ran: it is the earlier view (a bare NULL is text) without the tables the up
    # added, and it changed the function. Otherwise the comparison below would pass vacuously.
    for column <- @typed_nulls, do: assert(down.columns[column] == "text", column)
    assert down.tables == %{}
    refute down.function == before.function
    assert before.tables |> Map.keys() |> Enum.sort() == tables()

    # Dropping and recreating the view keeps its grants and its owner in this direction too.
    assert down.privileges == before.privileges
    assert down.owner == before.owner

    run!(migration, :up)

    assert snapshot() == before
  end

  test "the privileges the view held are among what is compared", %{migration: _} do
    privileges = snapshot().privileges

    assert Enum.any?(
             privileges,
             &(&1.privilege == "SELECT" and &1.grantable and &1.column == nil)
           )

    assert Enum.any?(privileges, &(&1.privilege == "UPDATE" and &1.column == "login"))
    assert Enum.any?(privileges, &(&1.privilege == "SELECT" and &1.column == "email"))
  end

  defp tables, do: ["strangler_observations", "strangler_receipts"]

  # `Code.require_file/1` returns the file's modules only the first time it loads it.
  defp migration_module do
    module = AshEnterprise.Repo.Migrations.TypeTheStranglerUserNulls
    Code.ensure_loaded?(module) || Code.require_file(@migration_file)
    module
  end

  # The migrator takes its table lock on the test's connection and then runs the migration in a
  # task that needs the same connection, which the sandbox would leave waiting for itself. The
  # lock guards against two nodes migrating at once; this test is the only one.
  defp run!(migration, direction) do
    Ecto.Migrator.run(Repo, [{@version, migration}], direction,
      all: true,
      log: false,
      migration_lock: false
    )
  end

  defp snapshot do
    %{
      columns: columns(),
      column_order: column_order(),
      definition: scalar("SELECT pg_get_viewdef('strangler.users'::regclass)"),
      owner:
        scalar(
          "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'strangler.users'::regclass"
        ),
      function:
        scalar("SELECT pg_get_functiondef('strangler_ledger_legacy_users()'::regprocedure)"),
      trigger:
        scalar("""
        SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname = 'strangler_ledger_legacy_users'
        """),
      tables: table_shapes(),
      privileges: privileges()
    }
  end

  defp scalar(sql), do: Repo.query!(sql).rows |> List.first() |> List.first()

  defp columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT attname, format_type(atttypid, atttypmod) FROM pg_attribute
       WHERE attrelid = 'strangler.users'::regclass AND attnum > 0 AND NOT attisdropped
      """)

    Map.new(rows, fn [name, type] -> {name, type} end)
  end

  defp column_order do
    %{rows: rows} =
      Repo.query!("""
      SELECT attname FROM pg_attribute
       WHERE attrelid = 'strangler.users'::regclass AND attnum > 0 AND NOT attisdropped
       ORDER BY attnum
      """)

    List.flatten(rows)
  end

  # Each table the migration adds, by name: its columns and its indexes. Absent tables are absent
  # from the map.
  defp table_shapes do
    for table <- tables(), exists?(table), into: %{} do
      %{rows: columns} =
        Repo.query!(
          """
          SELECT column_name, data_type, is_nullable, column_default
            FROM information_schema.columns
           WHERE table_schema = current_schema() AND table_name = $1
           ORDER BY ordinal_position
          """,
          [table]
        )

      %{rows: indexes} =
        Repo.query!(
          """
          SELECT indexname, indexdef FROM pg_indexes
           WHERE schemaname = current_schema() AND tablename = $1
           ORDER BY indexname
          """,
          [table]
        )

      {table, %{columns: columns, indexes: indexes}}
    end
  end

  defp exists?(table) do
    scalar("SELECT to_regclass(current_schema() || '.' || '#{table}') IS NOT NULL")
  end

  # The view's table-level and column-level grants, as the migration reads them.
  defp privileges do
    %{rows: rows} =
      Repo.query!("""
      SELECT pg_get_userbyid(a.grantor), CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
             a.privilege_type, a.is_grantable, NULL::text
        FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
       WHERE c.oid = 'strangler.users'::regclass
      UNION ALL
      SELECT pg_get_userbyid(a.grantor), CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
             a.privilege_type, a.is_grantable, att.attname::text
        FROM pg_attribute att CROSS JOIN LATERAL aclexplode(att.attacl) a
       WHERE att.attrelid = 'strangler.users'::regclass AND att.attnum > 0 AND att.attacl IS NOT NULL
      """)

    rows
    |> Enum.map(fn [grantor, grantee, privilege, grantable, column] ->
      %{
        grantor: grantor,
        grantee: grantee,
        privilege: privilege,
        grantable: grantable,
        column: column
      }
    end)
    |> Enum.sort_by(&{&1.grantee, &1.privilege, &1.column || ""})
  end
end
