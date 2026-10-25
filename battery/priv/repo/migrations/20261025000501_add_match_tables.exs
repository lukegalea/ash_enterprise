# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddMatchTables do
  @moduledoc "The MDM-3 fixture tables: rule sets and match candidates."

  use Ecto.Migration

  def up do
    create table(:mdm_match_rule_sets, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:golden_resource, :text, null: false)
      add(:rules, :map, null: false)
      add(:status, :text, null: false, default: "draft")
      add(:version, :integer, null: false, default: 1)
      add(:root_id, :uuid)
      add(:supersedes_id, :uuid)
      add(:content_hash, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create table(:mdm_match_candidates, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"))
      add(:staged_record_id, :uuid, null: false)
      add(:golden_resource, :text, null: false)
      add(:golden_id, :uuid, null: false)
      add(:score, :decimal, null: false)
      add(:explanation, :map)
      add(:band, :text)
      add(:status, :text, null: false, default: "pending")
      add(:human_verdict_ref, :map)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create unique_index(:mdm_match_candidates, [:staged_record_id, :golden_resource, :golden_id],
             name: :mdm_match_candidates_one_pair
           )
  end

  def down do
    drop(table(:mdm_match_candidates))
    drop(table(:mdm_match_rule_sets))
  end
end
