defmodule AshEnterprise.Canonical.CalendarEvent.TemporalCutover do
  @moduledoc """
  The SQL that turns the existing `canonical_calendar_events` table into a
  temporal one (ADR 0049, PROD-47), declared as custom statements on
  `AshEnterprise.Canonical.CalendarEvent` so `mix ash.codegen` emits it.

  The migration generator handles a temporal table it creates, not one it
  converts. Diffing the old snapshot against the temporal one, it adds the
  `valid_at` column and drops the foreign keys that touch the table, and
  stops there:

    * the primary key stays `(id)`, and a second version of an event would
      violate it. The temporal key is `PRIMARY KEY (id, valid_at WITHOUT
      OVERLAPS)`;
    * the identities stay plain unique indexes, and a second version of an
      event would violate those too. On a temporal table each is an
      exclusion constraint over the period (`WITH &&`), unique at every
      instant, under the name the generator gives one on a fresh table
      (`<table>_<identity>_index`), which is the name ash_postgres's temporal
      upsert names as its arbiter;
    * it drops `erasure_scope_id`'s and `organizer_id`'s foreign keys,
      because one side of each relationship is temporal. Only a key that
      points *at* a temporal table is unenforceable; these point from it at
      ordinary tables, so they are put back as they were.

  ## Existing rows

  Every row becomes the first version of its event, valid from the row's
  `inserted_at` onward: what the calendar holds now is what it is known to
  have held since the event was first projected. The column is added with
  a `tstzrange(now(), NULL)` default (`migration_defaults` on the
  resource) only so the `NOT NULL` column can be added to a table that has
  rows; the statement then sets each row's lower bound. Every write through
  Ash supplies the period itself, so the default never decides one.

  A row rewritten before the cutover (a reschedule then, `updated_at` after
  `inserted_at`) carries its current values back to its `inserted_at`: the
  table never kept the old ones. The business-events ledger's
  `calendar_event.changed` facts do keep the times and statuses, if a
  backfill of those versions is ever wanted.

  ## Safe to re-run, and reversible

  Each step checks the catalog first, so a statement that already ran does
  nothing. Their `down`s undo them: the history collapses to each event's
  latest version (the one an ordinary key can hold), the plain key and
  unique indexes come back, and the generator's `down` then drops
  `valid_at` and restores the foreign keys it dropped.

  The SQL avoids double quotes, backslashes and interpolation: on a temporal
  resource the generator writes it into the migration's Elixir source as it
  is. Table names are unqualified, so they resolve in the migrator's schema.
  """

  @table "canonical_calendar_events"

  @identities [
    {"canonical_calendar_events_unique_external_index", ["external_system", "external_id"]},
    {"canonical_calendar_events_unique_provider_uid_index", ["external_system", "external_uid"]}
  ]

  @foreign_keys [
    {"canonical_calendar_events_erasure_scope_id_fkey",
     "FOREIGN KEY (erasure_scope_id) REFERENCES erasure_scopes(id) ON DELETE RESTRICT"},
    {"canonical_calendar_events_organizer_id_fkey",
     "FOREIGN KEY (organizer_id) REFERENCES canonical_people(id)"}
  ]

  @doc "The period, the temporal primary key and the period-aware identities."
  @spec temporal_up() :: String.t()
  def temporal_up do
    """
    DO $temporal$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('#{@table}') AND contype = 'p' AND conperiod
      ) THEN
        UPDATE #{@table} SET valid_at = tstzrange(inserted_at AT TIME ZONE 'UTC', NULL);
        ALTER TABLE #{@table} DROP CONSTRAINT IF EXISTS #{@table}_pkey;
        ALTER TABLE #{@table} ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS);
      END IF;
    #{Enum.map_join(@identities, "\n", &exclusion_up/1)}
    END
    $temporal$
    """
  end

  @doc "Collapses each event to its latest version and restores the plain key and indexes."
  @spec temporal_down() :: String.t()
  def temporal_down do
    """
    DO $temporal$
    BEGIN
    #{Enum.map_join(@identities, "\n", &exclusion_down/1)}
      IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('#{@table}') AND contype = 'p' AND conperiod
      ) THEN
        DELETE FROM #{@table} older USING #{@table} newer
          WHERE older.id = newer.id AND lower(older.valid_at) < lower(newer.valid_at);
        ALTER TABLE #{@table} DROP CONSTRAINT #{@table}_pkey;
        ALTER TABLE #{@table} ADD PRIMARY KEY (id);
      END IF;
    #{Enum.map_join(@identities, "\n", &unique_index_down/1)}
    END
    $temporal$
    """
  end

  @doc "Puts back the foreign keys from the table to ordinary tables."
  @spec foreign_keys_up() :: String.t()
  def foreign_keys_up do
    """
    DO $fkeys$
    BEGIN
    #{Enum.map_join(@foreign_keys, "\n", &foreign_key_up/1)}
    END
    $fkeys$
    """
  end

  @doc "Drops them again, so the generator's `down` can restore its own."
  @spec foreign_keys_down() :: String.t()
  def foreign_keys_down do
    """
    DO $fkeys$
    BEGIN
    #{Enum.map_join(@foreign_keys, "\n", fn {name, _definition} -> "  ALTER TABLE #{@table} DROP CONSTRAINT IF EXISTS #{name};" end)}
    END
    $fkeys$
    """
  end

  defp exclusion_up({name, columns}) do
    """
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('#{@table}') AND conname = '#{name}' AND contype = 'x'
      ) THEN
        DROP INDEX IF EXISTS #{name};
        ALTER TABLE #{@table} ADD CONSTRAINT #{name}
          EXCLUDE USING gist (#{Enum.map_join(columns, ", ", &"#{&1} WITH =")}, valid_at WITH &&);
      END IF;
    """
  end

  defp exclusion_down({name, _columns}) do
    "  ALTER TABLE #{@table} DROP CONSTRAINT IF EXISTS #{name};"
  end

  defp unique_index_down({name, columns}) do
    "  CREATE UNIQUE INDEX IF NOT EXISTS #{name} ON #{@table} (#{Enum.join(columns, ", ")});"
  end

  defp foreign_key_up({name, definition}) do
    """
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('#{@table}') AND conname = '#{name}'
      ) THEN
        ALTER TABLE #{@table} ADD CONSTRAINT #{name} #{definition};
      END IF;
    """
  end
end
