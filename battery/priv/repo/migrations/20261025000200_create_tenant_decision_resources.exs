# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.TestRepo.Migrations.CreateTenantDecisionResources do
  @moduledoc """
  A second, tenant-scoped copy of the decision tables.

  They are the same shape as their untenanted twins with `organization_id` added,
  and every unique index gains the tenant column -- otherwise one organization's
  draft of a key would block another organization's, which is a data leak wearing
  a constraint violation as a disguise.
  """

  use Ecto.Migration

  def up do
    create table(:tenant_dmn_definitions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id, :uuid, null: false
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

    create unique_index(:tenant_dmn_definitions, [:organization_id, :key, :version])

    create unique_index(:tenant_dmn_definitions, [:organization_id, :key, :status],
             where: "status = 'draft'"
           )

    create table(:tenant_dmn_evaluations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id, :uuid, null: false
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

    create index(:tenant_dmn_evaluations, [:organization_id, :definition_id])
    create index(:tenant_dmn_evaluations, [:organization_id, :correlation_id])
  end

  def down do
    drop table(:tenant_dmn_evaluations)
    drop table(:tenant_dmn_definitions)
  end
end
