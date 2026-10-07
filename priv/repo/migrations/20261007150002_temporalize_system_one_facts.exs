defmodule AshEnterprise.Repo.Migrations.TemporalizeSystemOneFacts do
  @moduledoc """
  The facts temporal-swap cut-over (design note §5.2; AST-149): the
  SystemOne facts table moves onto the temporal contract.

  Facts are DERIVED data — the migration never translates rows. Per §5.2
  the legacy table is archived by rename and the fresh temporal table is
  created empty; the periods are rebuilt afterwards by replaying the
  recorded admissions in `effective_at` order through the temporal
  materialiser (`mix ash_enterprise.system_one.replay_facts`, §5.2:
  "replay your admissions" — the replay-equivalence property, AST-148,
  is what makes this correct).

  Also lands one unrelated contract drift the new ash_judgments pin
  carries: the judgment ledger's `family` is nullable (NULL exactly on an
  exploratory observation, the explore tier's widening).
  """

  use Ecto.Migration

  @archive_table "system_one_facts_legacy_20261007"
  @archive_index "system_one_facts_legacy_20261007_unique_id_index"

  def up do
    # ── §5.2 archive: rename, never drop ─────────────────────────────────
    # The legacy shape (superseded_by, uniqueness-by-convention) is kept
    # intact under an archived name, its identity index renamed along with
    # it so the fresh table below can claim the canonical names.
    execute("ALTER TABLE \"system_one_facts\" RENAME TO \"#{@archive_table}\"")
    execute("ALTER INDEX \"system_one_facts_unique_id_index\" RENAME TO \"#{@archive_index}\"")

    # ── The fresh temporal table ─────────────────────────────────────────
    # The §7.4 contract with the period (valid_at) and scope_hash; no
    # superseded_by. One open period per (subject_type, subject_id,
    # predicate, scope_hash) is enforced by the WITHOUT OVERLAPS exclusion
    # (PG18 + btree_gist, the platform baseline).
    create table(:system_one_facts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()")

      add :version_number, :bigint, null: false, default: 1
      add :import_sequence_number, :bigint
      add :overridden_created_on, :utc_datetime_usec
      add :modified_on_behalf_by_id, :uuid
      add :created_on_behalf_by_id, :uuid
      add :modified_by_id, :uuid
      add :created_by_id, :uuid
      add :modified_on, :utc_datetime_usec, null: false
      add :created_on, :utc_datetime_usec, null: false

      add :recorded_at, :utc_datetime_usec, null: false
      add :subject, :map, null: false
      add :subject_type, :text, null: false
      add :subject_id, :text, null: false
      add :predicate, :text, null: false
      add :value, :text, null: false
      add :holds, :boolean, null: false
      add :scope, :map
      add :scope_hash, :text, null: false
      add :subject_state_digest, :text
      add :valid_until, :utc_datetime_usec
      add :admission_grade, :text, null: false
      add :admission_id, :uuid
      add :valid_at, :tstzrange, null: false
    end

    create unique_index(:system_one_facts, [:id], name: :system_one_facts_unique_id_index)

    execute(
      "ALTER TABLE \"system_one_facts\" ADD CONSTRAINT \"system_one_facts_unique_subject_predicate_scope_index\" EXCLUDE USING gist (subject_type WITH =, subject_id WITH =, predicate WITH =, scope_hash WITH =, valid_at WITH &&)"
    )

    # ── Unrelated contract drift the new ash_judgments pin carries ───────
    alter table(:system_one_judgments) do
      modify :family, :text, null: true
    end
  end

  def down do
    drop constraint(:system_one_facts, "system_one_facts_unique_subject_predicate_scope_index")
    drop unique_index(:system_one_facts, [:id], name: :system_one_facts_unique_id_index)
    drop table(:system_one_facts)

    execute("ALTER TABLE \"#{@archive_table}\" RENAME TO \"system_one_facts\"")
    execute("ALTER INDEX \"#{@archive_index}\" RENAME TO \"system_one_facts_unique_id_index\"")

    alter table(:system_one_judgments) do
      modify :family, :text, null: false
    end
  end
end
