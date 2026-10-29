# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Test.Repo.Migrations.AddProjections do
  @moduledoc """
  BIZEV-8's storage: the projector engine's internal tables (checkpoint,
  dead-letter, registry — under the suite's `bizev_projection_` prefix)
  and the temporal canonical projection the demo projector drains into
  (`pipeline_histories` — one grain per (region, subject), one period per
  truth interval, `WITHOUT OVERLAPS`-keyed like the raw layer).
  """

  use Ecto.Migration

  def up do
    create table(:bizev_projection_checkpoints, primary_key: false) do
      add(:projection_name, :text, null: false, primary_key: true)
      add(:last_seen_event_id, :bigint)
      add(:events_processed, :bigint, null: false, default: 0)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create table(:bizev_projection_dead_letter_events, primary_key: false) do
      add(:projection_name, :text, null: false, primary_key: true)
      add(:event_id, :bigint, null: false, primary_key: true)
      add(:status, :text, null: false, default: "failed")
      add(:error_class, :text, null: false)
      add(:error_message, :text, null: false)
      add(:stacktrace, :text)
      add(:failed_at, :utc_datetime_usec, null: false)
      add(:replayed_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create table(:bizev_projection_registry, primary_key: false) do
      add(:name, :text, null: false, primary_key: true)
      add(:status, :text, null: false, default: "active")
      add(:version, :bigint, null: false, default: 1)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create table(:pipeline_histories, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:region, :text, null: false)
      add(:subject, :text, null: false)
      add(:stage, :text)
      add(:amount, :bigint)
      add(:corrections, :bigint, null: false, default: 0)
      add(:valid_at, :tstzrange, null: false)
      add(:recorded_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    execute(
      "ALTER TABLE \"pipeline_histories\" ADD PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)"
    )

    execute(
      "ALTER TABLE \"pipeline_histories\" ADD CONSTRAINT \"pipeline_histories_by_grain_index\" " <>
        "EXCLUDE USING gist (region WITH =, subject WITH =, valid_at WITH &&)"
    )
  end

  def down do
    execute(
      "ALTER TABLE \"pipeline_histories\" DROP CONSTRAINT IF EXISTS \"pipeline_histories_by_grain_index\""
    )

    alter table(:pipeline_histories) do
      remove(:recorded_at)
    end

    execute(
      "ALTER TABLE \"pipeline_histories\" DROP CONSTRAINT IF EXISTS \"pipeline_histories_pkey\""
    )

    drop(table(:pipeline_histories))

    drop(table(:bizev_projection_registry))
    drop(table(:bizev_projection_dead_letter_events))
    drop(table(:bizev_projection_checkpoints))
  end
end
