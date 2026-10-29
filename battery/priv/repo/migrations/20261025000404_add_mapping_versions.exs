# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Test.Repo.Migrations.AddMappingVersions do
  @moduledoc """
  The `mapping_versions` table — BIZEV-5's versioned mapping artifacts.

  One row per compiled mapping declaration, content-addressed: the
  `(mapping_name, version_hash)` pair is the identity (the ledger's
  provenance join), and `artifact` is the hashed form stored as
  replayable data.
  """

  use Ecto.Migration

  def up do
    create table(:mapping_versions, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:mapping_name, :text, null: false)
      add(:version_hash, :text, null: false)
      add(:source_name, :text, null: false)
      add(:stream_name, :text, null: false)
      add(:status, :text, null: false)
      add(:artifact, :map, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:mapping_versions, [:mapping_name, :version_hash],
             name: "mapping_versions_unique_name_hash_index"
           ))
  end

  def down do
    drop_if_exists(
      unique_index(:mapping_versions, [:mapping_name, :version_hash],
        name: "mapping_versions_unique_name_hash_index"
      )
    )

    drop(table(:mapping_versions))
  end
end
