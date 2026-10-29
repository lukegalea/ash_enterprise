# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Test.Repo.Migrations.PartitionSourceRecords do
  @moduledoc """
  BIZEV-12: the raw layer becomes RANGE-partitioned by `fetched_at`
  (the observation instant — §1.3's period basis), monthly, hand-maintained
  (ash_postgres codegen does not model partitioning; the house pattern).

  The repo is pre-production: this is the GREENFIELD strategy — the
  unpartitioned table is replaced outright (its data was per-test
  sandbox state). The shape:

    * parent `source_records`, PARTITION BY RANGE (fetched_at) — the
      partition key joins the PK;
    * a DEFAULT partition (catch-all until a month is sliced);
    * explicit monthly partitions for the fixture year, each carrying
      the per-partition identity exclusion (the identity is enforced
      WITHIN a partition; cross-month overlaps are precluded
      operationally — periods are `[fetched_at, next observation)` and
      backdated landings are refused).

  Runtime partition management lives in
  `AshDiscreteBusinessEvents.Retention` (`ensure_partition!/3`,
  `purge_before/3`).
  """

  use Ecto.Migration

  @months Enum.map(1..12, &Integer.to_string/1)

  def up do
    drop_existing()

    create table(:source_records, primary_key: false, options: "PARTITION BY RANGE (fetched_at)") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:source, :text, null: false)
      add(:stream, :text, null: false)
      add(:external_id, :text, null: false)
      add(:region, :text, null: false)
      add(:residency_tag, :text, null: false)
      add(:raw_payload, :map, null: false)
      add(:source_metadata, :map)
      add(:cursor, :map)
      add(:fetched_at, :timestamptz, null: false)
      add(:valid_at, :tstzrange, null: false)
      add(:recorded_at, :timestamptz,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    execute(
      "ALTER TABLE \"source_records\" ADD PRIMARY KEY (id, fetched_at, valid_at WITHOUT OVERLAPS)"
    )

    # The catch-all: everything not yet sliced into an explicit month.
    execute(
      "CREATE TABLE source_records_default PARTITION OF source_records DEFAULT"
    )

    Enum.each(@months, &create_month_partition/1)
  end

  defp create_month_partition(m) do
    m = String.to_integer(m)
    suffix = String.pad_leading(Integer.to_string(m), 2, "0")
    {to_year, to_month} = if m == 12, do: {2027, 1}, else: {2026, m + 1}

    execute("""
    CREATE TABLE source_records_2026_#{suffix} PARTITION OF source_records
      FOR VALUES FROM ('2026-#{suffix}-01') TO ('#{to_year}-#{String.pad_leading(Integer.to_string(to_month), 2, "0")}-01')
    """)

    execute("""
    ALTER TABLE source_records_2026_#{suffix}
      ADD CONSTRAINT source_records_2026_#{suffix}_identity_excl
      EXCLUDE USING gist (source WITH =, stream WITH =, external_id WITH =, region WITH =, valid_at WITH &&)
    """)
  end

  defp drop_existing do
    # Pre-production: the unpartitioned table's data was per-test sandbox
    # state; the partitioned strategy replaces it outright.
    execute("DROP TABLE IF EXISTS source_records")
  end

  def down do
    execute("DROP TABLE IF EXISTS source_records")

    create table(:source_records, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:source, :text, null: false)
      add(:stream, :text, null: false)
      add(:external_id, :text, null: false)
      add(:region, :text, null: false)
      add(:residency_tag, :text, null: false)
      add(:raw_payload, :map, null: false)
      add(:source_metadata, :map)
      add(:cursor, :map)
      add(:fetched_at, :utc_datetime_usec, null: false)
      add(:valid_at, :tstzrange, null: false)
      add(:recorded_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    execute("ALTER TABLE \"source_records\" ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)")

    execute(
      "ALTER TABLE \"source_records\" ADD CONSTRAINT \"source_records_unique_observation_index\" " <>
        "EXCLUDE USING gist (source WITH =, stream WITH =, external_id WITH =, region WITH =, valid_at WITH &&)"
    )
  end
end
