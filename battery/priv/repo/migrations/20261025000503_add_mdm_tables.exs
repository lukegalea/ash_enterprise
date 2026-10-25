# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddMdmTables do
  @moduledoc "Hand-maintained while the package is 0.x: the fixture tables."

  use Ecto.Migration

  def up do
    # citext backs the fixture Person's :email — before any table that uses it.
    execute("CREATE EXTENSION IF NOT EXISTS \"citext\"")

    create table(:fixture_people, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:name, :text)
      add(:email, :citext)
      add(:tier, :text)
      add(:joined_on, :date)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create table(:mdm_mappings, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:direction, :text, null: false)
      add(:source, :text, null: false)
      add(:stream, :text, null: false)
      add(:target_resource, :text, null: false)
      add(:field_rules, :map, null: false)
      add(:observed_schema, :map)
      add(:status, :text, null: false, default: "draft")
      add(:version, :integer, null: false, default: 1)
      add(:root_id, :uuid)
      add(:supersedes_id, :uuid)
      add(:content_hash, :text)
      add(:validation_findings, :map)
      add(:activation_note, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create index(:mdm_mappings, [:direction, :source, :stream, :target_resource],
             unique: true,
             where: "status = 'active'",
             name: :mdm_mappings_one_active
           )
  end

  def down do
    drop(table(:mdm_mappings))
    drop(table(:fixture_people))
  end
end
