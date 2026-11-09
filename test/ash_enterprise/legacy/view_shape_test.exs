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

    test "name the legacy columns in the ledger trigger instead of reading the whole row" do
      %{rows: [[source]]} =
        Repo.query!("""
        SELECT prosrc FROM pg_proc WHERE proname = 'strangler_ledger_legacy_users'
        """)

      assert source =~ "jsonb_build_object('id', NEW.\"id\""
      refute source =~ "to_jsonb(NEW)"
    end
  end
end
