# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.TestRepo.Migrations.CreateDecisionResources do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:dmn_definitions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :key, :text, null: false
      add :name, :text, null: false
      add :version, :integer, null: false
      add :status, :text, null: false, default: "draft"
      add :xml, :text, null: false
      add :graph, :map, default: nil
      add :errors, {:array, :map}, default: []
      add :content_hash, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:dmn_definitions, [:key, :version])
    create unique_index(:dmn_definitions, [:key, :status], where: "status = 'draft'")

    create table(:dmn_evaluations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :definition_id, :uuid, null: false
      add :definition_key, :text, null: false
      add :definition_version, :integer, null: false
      add :decision_id, :text, null: false
      add :inputs, :map, default: %{}
      add :outputs, :map, default: %{}
      add :matched_rule_ids, {:array, :text}, default: []
      add :hit_policy, :text
      add :duration_us, :integer
      add :error, :map
      add :correlation_id, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:dmn_evaluations, [:definition_id])
    create index(:dmn_evaluations, [:correlation_id])
  end

  def down do
    drop table(:dmn_evaluations)
    drop table(:dmn_definitions)
  end
end
