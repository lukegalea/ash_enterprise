# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshMdm.Test.Repo.Migrations.AddSurvivorship do
  @moduledoc "The MatchRuleSet survivorship policy column."

  use Ecto.Migration

  def up do
    alter table(:mdm_match_rule_sets) do
      add(:survivorship, :map)
    end
  end

  def down do
    alter table(:mdm_match_rule_sets) do
      remove(:survivorship)
    end
  end
end
