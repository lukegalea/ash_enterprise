# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Test.Repo.Migrations.AddProcessRef do
  @moduledoc """
  §5.2's process correlation slot: `process_ref` on the ledger and its
  simulation twin — the BPMN-side pointer for process-relevant events,
  set by the mapping's `process_key` or the caller. Opaque to this
  package; nullable (most events are not process-relevant).
  """

  use Ecto.Migration

  def up do
    alter table(:ledger_events) do
      add(:process_ref, :text)
    end

    alter table(:ledger_simulation_events) do
      add(:process_ref, :text)
    end
  end

  def down do
    alter table(:ledger_simulation_events) do
      remove(:process_ref)
    end

    alter table(:ledger_events) do
      remove(:process_ref)
    end
  end
end
