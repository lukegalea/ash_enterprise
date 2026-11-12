defmodule AshEnterprise.Legacy.StranglerCodegenTest do
  @moduledoc """
  `mix ash.codegen --check` covers the strangler compatibility layer.

  The gate being tested: the committed snapshot under `priv/strangler_snapshots`
  records what the newest installed strangler DDL contains, and the renderer
  still produces exactly that. Every statement here is rendered from compiled
  resources — no database is involved. That the snapshot itself is honest
  (matches what the applied migrations installed, and re-applies to a migrated
  database without changing it) was proven once at seed time and is not
  re-proven per test run.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Legacy.StranglerCodegen

  @resource AshEnterprise.Legacy.User

  describe "the committed snapshot" do
    test "the renderer still produces what is installed" do
      assert StranglerCodegen.pending() == []
    end

    test "it covers the strangled resource, with the pieces the layer promises" do
      resource = AshEnterprise.Legacy.User
      assert %{^resource => statements} = StranglerCodegen.rendered()
      assert length(statements) >= 5

      sql = statements |> Enum.map_join("\n", & &1.up)

      # Schema, view, key index, ledger trigger: what the strangler migration
      # installs for this resource, named by what the SQL builds.
      assert sql =~ ~s|CREATE SCHEMA IF NOT EXISTS "strangler"|
      assert sql =~ ~s|CREATE OR REPLACE VIEW "strangler"."users"|
      assert sql =~ "CREATE INDEX IF NOT EXISTS strangler_users_key_idx ON legacy.users"
      assert sql =~ "CREATE OR REPLACE TRIGGER"
    end
  end

  describe "pending/1" do
    test "a changed statement is reported as pending, naming the resource" do
      # The snapshot is the stale half: it holds an older body of the first
      # statement, the way the installed DDL predates a mapping change.
      root =
        doctored_root(fn doc ->
          update_in(doc, ["statements", Access.at(0), "up"], &(&1 <> "\n-- older body"))
        end)

      [entry] = StranglerCodegen.pending(snapshot_root: root)

      assert entry.resource == @resource
      assert entry.status == :changed
      assert entry.summary =~ "changed: "

      # What is pending is the current render — the statement to put in the
      # next migration — not the stale text.
      [{_name, up} | _] = entry.pending
      first = StranglerCodegen.rendered()[@resource] |> List.first()
      assert up == String.trim_trailing(first.up)
    end

    test "a missing snapshot reports every statement of the resource" do
      root = Path.join(System.tmp_dir!(), "strangler-snapshots-missing-#{System.unique_integer()}")

      [entry] = StranglerCodegen.pending(snapshot_root: root)

      assert entry.resource == @resource
      assert entry.status == :missing
      assert entry.summary == "no snapshot yet"
      assert length(entry.pending) == length(StranglerCodegen.rendered()[@resource])
    end

    test "a corrupt snapshot is reported, not crashed on" do
      root = snapshot_root()
      path = StranglerCodegen.snapshot_path(root, @resource)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json at all")

      [entry] = StranglerCodegen.pending(snapshot_root: root)

      assert entry.resource == @resource
      assert entry.status == :invalid
    end

    test "a statement added by a mapping change is reported as added" do
      # The snapshot is stale: it predates the statement the renderer now
      # produces, so the renderer has one statement the snapshot lacks.
      root =
        doctored_root(fn doc ->
          update_in(doc, ["statements"], &Enum.drop(&1, -1))
        end)

      [entry] = StranglerCodegen.pending(snapshot_root: root)

      assert entry.status == :changed
      assert entry.summary =~ "added: "

      last = StranglerCodegen.rendered()[AshEnterprise.Legacy.User] |> List.last()
      assert entry.pending == [{to_string(last.name), String.trim_trailing(last.up)}]
    end

    test "a statement removed by a mapping change is reported as removed" do
      # The snapshot holds a statement the renderer no longer produces.
      root =
        doctored_root(fn doc ->
          update_in(doc, ["statements"], fn statements ->
            statements ++ [%{"name" => "retired_statement", "up" => "SELECT 1;"}]
          end)
        end)

      [entry] = StranglerCodegen.pending(snapshot_root: root)

      assert entry.status == :changed
      assert entry.summary =~ "removed: 1"
      # Nothing is pending for a removal: the next migration carries only what
      # the renderer still produces.
      assert entry.pending == []
    end

    test "freshly written snapshots are clean" do
      root = snapshot_root()
      StranglerCodegen.write_snapshots!(snapshot_root: root)

      assert StranglerCodegen.pending(snapshot_root: root) == []
    end
  end

  describe "next_version/1" do
    test "it allocates strictly after an existing newer file" do
      dir = Path.join(System.tmp_dir!(), "migrations-#{System.unique_integer()}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "20991231235959_someone_elses.exs"), "")

      version = StranglerCodegen.next_version(dir)

      assert String.match?(version, ~r/^\d{14}$/)
      assert String.to_integer(version) > 20_991_231_235_959
    end

    test "it stays strictly after AshPostgres's in-process counter" do
      dir = Path.join(System.tmp_dir!(), "migrations-#{System.unique_integer()}")
      File.mkdir_p!(dir)

      # The counter AshPostgres's generator publishes into; whichever extension
      # runs first, the second must not land on the same second.
      Process.put(:ash_postgres_last_migration_timestamp, "20300101000000")

      version = StranglerCodegen.next_version(dir)

      assert String.to_integer(version) > 20_300_101_000_000
    end

    test "it is a 14-digit version on an empty directory" do
      dir = Path.join(System.tmp_dir!(), "migrations-#{System.unique_integer()}")
      File.mkdir_p!(dir)

      assert String.match?(StranglerCodegen.next_version(dir), ~r/^\d{14}$/)
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp snapshot_root do
    Path.join(System.tmp_dir!(), "strangler-snapshots-#{System.unique_integer()}")
  end

  # Renders the current statements to a fresh snapshot dir, then lets the test
  # rewrite the JSON the way a stale mapping would have left it.
  defp doctored_root(transform) do
    root = snapshot_root()
    StranglerCodegen.write_snapshots!(snapshot_root: root)

    path = StranglerCodegen.snapshot_path(root, @resource)
    doc = JSON.decode!(File.read!(path))
    File.write!(path, JSON.encode!(transform.(doc)))

    root
  end
end
