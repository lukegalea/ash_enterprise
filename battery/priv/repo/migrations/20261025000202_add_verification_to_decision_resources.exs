# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.TestRepo.Migrations.AddVerificationToDecisionResources do
  @moduledoc """
  The publish-time verification result, stored beside the compile errors it
  complements rather than replaces.

  Both the untenanted and the tenant-scoped definition tables carry it: they are
  the same resource macro against two tables, and a verification that existed
  only for one kind of deployment would be a guarantee that silently depended on
  how the host chose to spell "tenant".
  """

  use Ecto.Migration

  def up do
    alter table(:dmn_definitions) do
      add :verification, :map
    end

    alter table(:tenant_dmn_definitions) do
      add :verification, :map
    end
  end

  def down do
    alter table(:dmn_definitions) do
      remove :verification
    end

    alter table(:tenant_dmn_definitions) do
      remove :verification
    end
  end
end
