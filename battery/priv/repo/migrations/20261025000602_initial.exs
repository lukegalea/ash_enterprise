# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.Initial do
  @moduledoc """
  Control plane, data plane and event-log tables.

  Hand-maintained (not generated) because the resources resolve their repo
  and table prefix at compile time from application env; codegen against the
  test repo would bake test-only names in. Column sets mirror the resources
  exactly.
  """

  use Ecto.Migration

  def change do
    create table(:ash_compliance_catalogs, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid
      add :name, :text, null: false
      add :description, :text
      add :oscal_uuid, :text
      timestamps()
    end

    create unique_index(:ash_compliance_catalogs, [:organization_id, :name])

    create table(:ash_compliance_catalog_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :catalog_id, :uuid, null: false
      add :version, :text, null: false
      add :source, :text
      add :content_hash, :text, null: false
      add :published_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:ash_compliance_catalog_versions, [:catalog_id, :version])
    create unique_index(:ash_compliance_catalog_versions, [:catalog_id, :content_hash])

    create table(:ash_compliance_controls, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid
      add :catalog_id, :uuid
      add :control_id, :text, null: false
      add :title, :text
      add :family, :text
      timestamps()
    end

    create unique_index(:ash_compliance_controls, [:organization_id, :control_id])

    create table(:ash_compliance_control_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :control_id, :uuid, null: false
      add :version, :text, null: false
      add :statement, :text
      add :params, {:array, :map}, default: []
      add :citations, {:array, :text}, default: []
      add :status, :text, null: false, default: "draft"
      timestamps()
    end

    create unique_index(:ash_compliance_control_revisions, [:control_id, :version])

    create table(:ash_compliance_profiles, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid
      add :catalog_id, :uuid
      add :name, :text, null: false
      add :oscal_uuid, :text
      timestamps()
    end

    create unique_index(:ash_compliance_profiles, [:organization_id, :name])

    create table(:ash_compliance_profile_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :profile_id, :uuid, null: false
      add :version, :text, null: false
      add :source, :text
      add :operations, {:array, :map}, default: []
      add :content_hash, :text, null: false
      timestamps()
    end

    create unique_index(:ash_compliance_profile_revisions, [:profile_id, :version])

    create table(:ash_compliance_rule_set_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid
      add :name, :text, null: false
      add :revision, :text, null: false, default: "1"
      add :layer, :text, null: false
      add :combining, :text, null: false, default: "deny_overrides"
      add :source_module, :text
      add :rules_json, :text, null: false
      add :content_hash, :text, null: false
      add :status, :text, null: false, default: "draft"
      timestamps()
    end

    create unique_index(:ash_compliance_rule_set_revisions, [:organization_id, :name, :revision])
    create index(:ash_compliance_rule_set_revisions, [:status])

    create table(:ash_compliance_policy_bundles, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid, null: false
      add :label, :text
      add :rules_json, :text, null: false
      add :content_hash, :text, null: false
      add :manifest_revision, :text, null: false
      add :compiler_version, :text, null: false
      add :contributions, {:array, :map}, default: []
      add :status, :text, null: false, default: "compiled"
      add :active_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:ash_compliance_policy_bundles, [:organization_id, :content_hash])

    create table(:ash_compliance_tenant_policy_sets, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid, null: false
      add :name, :text
      add :profile_revision_ids, {:array, :uuid}, default: []
      add :rule_set_revision_ids, {:array, :uuid}, default: []
      add :active_policy_bundle_id, :uuid
      timestamps()
    end

    create unique_index(:ash_compliance_tenant_policy_sets, [:organization_id])

    create table(:ash_compliance_policy_overrides, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid, null: false
      add :kind, :text, null: false
      add :rule_id, :text, null: false
      add :reason, :text, null: false
      add :approver, :text, null: false
      add :approved_at, :utc_datetime_usec, null: false
      add :starts_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :scope_subject_type, :text
      add :scope_subject_id, :text
      add :compensating_controls, {:array, :text}, default: []
      add :replacement_rules_json, :text
      timestamps()
    end

    create index(:ash_compliance_policy_overrides, [:organization_id, :rule_id])

    create table(:ash_compliance_control_mappings, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid
      add :gap, :text, null: false
      add :control_id, :text, null: false
      add :profile_revision_id, :uuid
      add :jurisdiction, :text
      add :notes, :text
      timestamps()
    end

    create unique_index(:ash_compliance_control_mappings, [:organization_id, :gap])

    create table(:ash_compliance_findings, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid, null: false
      add :control_id, :text, null: false
      add :subject_type, :text, null: false
      add :subject_id, :text, null: false
      add :status, :text, null: false, default: "unknown"
      add :severity, :text
      add :gap, :text
      add :breach_count, :integer, null: false, default: 0
      add :first_seen_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
      add :explanation, :text
      add :bundle_hash, :text
      add :rule_ids, {:array, :text}, default: []
      timestamps()
    end

    create unique_index(:ash_compliance_findings, [
             :organization_id,
             :control_id,
             :subject_type,
             :subject_id
           ])

    create table(:ash_compliance_compliance_evaluations, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid, null: false
      add :control_id, :text
      add :subject_type, :text
      add :subject_id, :text
      add :bundle_hash, :text, null: false
      add :bundle_revision, :text
      add :evaluator, :text, null: false
      add :compiler_version, :text
      add :outcome, :text, null: false
      add :fact_snapshot_hash, :text, null: false
      add :missing_facts, {:array, :text}, default: []
      add :rule_ids, {:array, :text}, default: []
      add :correlation_id, :text
      add :source_event_id, :text
      add :evaluated_at, :utc_datetime_usec, null: false
      timestamps(updated_at: false)
    end

    create index(:ash_compliance_compliance_evaluations, [
             :organization_id,
             :subject_type,
             :subject_id
           ])

    create table(:ash_compliance_evidence_artifacts, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :organization_id, :uuid, null: false
      add :control_id, :text, null: false
      add :subject_type, :text
      add :subject_id, :text
      add :hash, :text, null: false
      add :media_type, :text, null: false
      add :collector, :text, null: false
      add :method, :text, null: false
      add :chain_of_custody, {:array, :map}, default: []
      add :retention_class, :text
      add :collected_at, :utc_datetime_usec, null: false
      timestamps(updated_at: false)
    end

    create index(:ash_compliance_evidence_artifacts, [:organization_id, :control_id])

    # The event log. The projector engine's schemaless drain selects
    # practice_id and user_id by name, so they exist here as plain columns.
    create table(:ash_events, primary_key: false) do
      add :id, :bigserial, primary_key: true, null: false
      add :record_id, :uuid, null: false
      add :version, :integer, null: false, default: 1
      add :resource, :text, null: false
      add :action, :text, null: false
      add :action_type, :text, null: false
      add :data, :map, null: false
      add :metadata, :map, null: false
      add :changed_attributes, :map, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :practice_id, :uuid
      add :user_id, :uuid
    end

    create index(:ash_events, [:resource, :action])
  end
end
