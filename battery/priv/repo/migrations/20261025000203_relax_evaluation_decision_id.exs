# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.TestRepo.Migrations.RelaxEvaluationDecisionId do
  @moduledoc """
  A failed evaluation is exactly the row an auditor most needs, and some
  failures happen before any decision could be resolved (an ambiguous document,
  a document with no decision at all). `decision_id` therefore cannot be
  required for the row that records the failure.
  """

  use Ecto.Migration

  def change do
    alter table(:dmn_evaluations) do
      modify :decision_id, :text, null: true, from: :text
    end

    alter table(:tenant_dmn_evaluations) do
      modify :decision_id, :text, null: true, from: :text
    end
  end
end
