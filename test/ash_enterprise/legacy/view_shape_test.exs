defmodule AshEnterprise.Legacy.ViewShapeTest do
  @moduledoc """
  The shape of the installed `strangler.users` view and of the objects the strangler
  generator installs beside it.

  `unmapped ..., as: :null` renders as a NULL cast to the attribute's Postgres type. A
  bare `NULL` is typed `text` by Postgres, so a uuid, timestamp or integer attribute read
  through such a view arrives as text. `CREATE OR REPLACE VIEW` cannot change a column's
  type, so a database migrated before the typed form needs the view dropped and created
  again; these tests are what says the database is in the typed state, whichever route
  (a fresh replay or the upgrade) got it there.
  """

  use AshEnterprise.DataCase, async: true

  alias AshEnterprise.Repo

  defp view_column_types do
    %{rows: rows} =
      Repo.query!("""
      SELECT a.attname, format_type(a.atttypid, a.atttypmod)
        FROM pg_attribute a
       WHERE a.attrelid = 'strangler.users'::regclass AND a.attnum > 0 AND NOT a.attisdropped
      """)

    Map.new(rows, fn [name, type] -> {name, type} end)
  end

  describe "the unmapped columns of strangler.users" do
    test "carry the Postgres type of the attribute they stand for" do
      types = view_column_types()

      expected = %{
        "created_by_id" => "uuid",
        "modified_by_id" => "uuid",
        "created_on_behalf_by_id" => "uuid",
        "modified_on_behalf_by_id" => "uuid",
        "overridden_created_on" => "timestamp with time zone",
        "import_sequence_number" => "bigint"
      }

      for {column, type} <- expected do
        assert Map.fetch!(types, column) == type, "#{column} should be #{type}"
      end
    end

    test "cover every attribute the unmapped declaration names" do
      declared =
        AshEnterprise.Legacy.User
        |> AshStrangler.Info.unmapped()
        |> Enum.flat_map(&List.wrap(&1.attributes))
        |> Enum.map(&Atom.to_string/1)

      assert declared != []
      assert Enum.all?(declared, &Map.has_key?(view_column_types(), &1))
    end
  end

  describe "the objects the generator installs for the ledger" do
    test "include the observation and receipt tables" do
      %{rows: rows} =
        Repo.query!("""
        SELECT table_name FROM information_schema.tables
         WHERE table_schema = current_schema()
           AND table_name IN ('strangler_observations', 'strangler_receipts')
         ORDER BY 1
        """)

      assert rows == [["strangler_observations"], ["strangler_receipts"]]
    end

    test "has one trigger on legacy.users that calls the ledger function" do
      assert [["strangler_ledger_legacy_users"]] =
               rows("""
               SELECT p.proname FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                WHERE t.tgrelid = 'legacy.users'::regclass AND t.tgname = 'strangler_ledger_legacy_users'
               """)
    end
  end

  describe "the ledger function, by what it writes" do
    test "an insert records the whole row, and an update records what changed" do
      id = insert_user!()

      [insert, update] =
        with_update(id, "UPDATE legacy.users SET last_name = 'Changed' WHERE id = $1")

      assert insert.operation == "insert"
      assert insert.primary_key == %{"id" => id}
      assert insert.old_row == nil
      assert Map.keys(insert.new_row) |> Enum.sort() == legacy_user_columns()
      assert insert.changed_columns == insert.new_row

      assert update.operation == "update"
      assert update.old_row["last_name"] == "Ledger"
      assert update.new_row["last_name"] == "Changed"
      assert update.changed_columns == %{"last_name" => "Changed"}
    end

    test "with the attribution declared, an insert and an update record who and from where" do
      declare_attribution!(origin: "rails-admin", actor: "4242")
      id = insert_user!()

      [insert, update] =
        with_update(id, "UPDATE legacy.users SET first_name = 'Ada' WHERE id = $1")

      for event <- [insert, update] do
        assert event.source_system == "rails-admin"
        assert event.source_user == "4242"
        assert event.actor_confidence == "asserted"
      end
    end

    test "a correlation id alone is attribution too, and leaves the other slots empty" do
      declare_attribution!(correlation_id: "corr-1")
      [event] = events_for(insert_user!())

      assert event.source_correlation_id == "corr-1"
      assert event.actor_confidence == "asserted"
      assert event.source_system == nil
      assert event.source_user == nil
    end

    test "with no attribution declared, the slots stay empty and the event is still written" do
      id = insert_user!()

      [insert, update] =
        with_update(id, "UPDATE legacy.users SET first_name = 'Ada' WHERE id = $1")

      for event <- [insert, update] do
        assert event.source_system == nil
        assert event.source_user == nil
        assert event.source_correlation_id == nil
        assert event.source_request_id == nil
        assert event.actor_confidence == nil
      end
    end

    test "empty declarations count as none" do
      declare_attribution!(origin: "", actor: "")
      [event] = events_for(insert_user!())

      assert event.source_system == nil
      assert event.source_user == nil
      assert event.actor_confidence == nil
    end
  end

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  # What `AshStrangler.Context` does for a transaction: transaction-local settings, which the
  # sandbox's transaction is.
  defp declare_attribution!(settings) do
    for {key, value} <- settings do
      Repo.query!("SELECT set_config($1, $2, true)", ["ash_strangler.#{key}", value])
    end
  end

  defp insert_user! do
    login = "shape-#{System.unique_integer([:positive])}"

    [[id]] =
      rows(
        """
        INSERT INTO legacy.users (login, email, first_name, last_name, state, created_at, updated_at)
        VALUES ($1, $2, 'Ledger', 'Ledger', 'active', now(), now())
        RETURNING id
        """,
        [login, "#{login}@corp.example"]
      )

    id
  end

  defp with_update(id, sql) do
    Repo.query!(sql, [id])
    events_for(id)
  end

  defp legacy_user_columns do
    "SELECT column_name FROM information_schema.columns WHERE table_schema = 'legacy' AND table_name = 'users'"
    |> rows()
    |> List.flatten()
    |> Enum.sort()
  end

  defp events_for(id) do
    ("SELECT operation, primary_key, old_row, new_row, changed_columns, source_system, source_user, " <>
       "source_correlation_id, source_request_id, actor_confidence " <>
       "FROM legacy_change_events WHERE source_schema = 'legacy' AND source_table = 'users' " <>
       "AND primary_key = jsonb_build_object('id', $1::bigint) ORDER BY id")
    |> rows([id])
    |> Enum.map(fn [op, pk, old, new, changed, system, user, corr, req, confidence] ->
      %{
        operation: op,
        primary_key: pk,
        old_row: old,
        new_row: new,
        changed_columns: changed,
        source_system: system,
        source_user: user,
        source_correlation_id: corr,
        source_request_id: req,
        actor_confidence: confidence
      }
    end)
  end
end
