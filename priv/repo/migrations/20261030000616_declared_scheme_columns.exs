# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshEnterprise.Repo.Migrations.DeclaredSchemeColumns do
  @moduledoc """
  `scheme` on `policy_bundles` and `rule_set_revisions`: the
  `AshCompliance.Layering` module a bundle was compiled under, or a revision
  belongs to. Nullable, and `NULL` is the default six-rank scheme, so every
  existing row keeps its meaning and the default compile reads exactly the
  rows it always read.

  Hand-maintained, like the rest of this directory (the resources resolve
  their repo/table at compile time from application env, so codegen would
  bake test-only names in); the DDL mirrors what
  `mix ash_postgres.generate_migrations` emits for two nullable text
  attributes.
  """

  use Ecto.Migration

  def up do
    alter table(:ash_compliance_policy_bundles) do
      add :scheme, :text
    end

    alter table(:ash_compliance_rule_set_revisions) do
      add :scheme, :text
    end
  end

  def down do
    alter table(:ash_compliance_rule_set_revisions) do
      remove :scheme
    end

    alter table(:ash_compliance_policy_bundles) do
      remove :scheme
    end
  end
end
