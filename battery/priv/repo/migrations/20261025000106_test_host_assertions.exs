# SPDX-FileCopyrightText: 2026 ash_evidence contributors <https://github.com/lukegalea/ash_evidence>
#
# SPDX-License-Identifier: MIT

defmodule AshEvidence.Repo.Migrations.TestHostAssertions do
  @moduledoc """
  The TEST HOST's assertion table — what a consumer of this package
  builds for `AshEvidence.Assertions.Fragment` on its own platform base.

  This migration is deliberately HAND-WRITTEN, not generated: the host
  assertion is not a package resource (it lives in no package snapshot),
  so `mix ash.codegen` never sees it. It demonstrates the exact shape a
  host writes for its own base — one plain table, no FK to the evidence
  tables (the packet/evaluation references are opaque and may dangle
  post-erasure), the create timestamp the events config would name.
  """

  use Ecto.Migration

  def up do
    create table(:test_host_assertions, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("(now() AT TIME ZONE 'utc')"))
      add(:record_version, :text, null: false, default: "1")
      add(:record_hash, :text)
      add(:packet_id, :uuid)
      add(:evaluation_id, :uuid)
      add(:disposition, :text, null: false)
      add(:distribution, :map, null: false)
      add(:aggregation_rule_version, :text, null: false)
      add(:observation_ids, {:array, :uuid}, null: false, default: [])
      add(:subject, :map, null: false)
      add(:predicate, :text, null: false)
      add(:subject_state_digest, :text, null: false)
      add(:question_set_hash, :text, null: false)
    end

    create unique_index(:test_host_assertions, [:id], name: "test_host_assertions_unique_id_index")
  end

  def down do
    drop_if_exists(
      unique_index(:test_host_assertions, [:id], name: "test_host_assertions_unique_id_index")
    )

    drop_if_exists(table(:test_host_assertions))
  end
end
