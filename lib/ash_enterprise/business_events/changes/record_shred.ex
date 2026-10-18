defmodule AshEnterprise.BusinessEvents.Changes.RecordShred do
  @moduledoc """
  Records a shred in the business-event ledger, in the shred's own
  transaction (ADR 0051, erasure-as-event).

  On `AshEnterprise.Erasure.Scope`'s `shred`, after the key is destroyed:
  every owner whose facts point at the scope gets one
  `:"retention.subject_erased"` tombstone in their own stream
  (`AshEnterprise.BusinessEvents.Recorder.shredded/1`). The facts themselves
  stay — they never held sealed content — and the tombstone says, in the
  ledger, that what they point at is gone.

  A failure to record fails the shred, as a failed record fails a
  projection: a shred and its tombstones commit together or not at all, and
  the operator retries. Off when `AshEnterprise.BusinessEvents.emit?/0` is
  false, like every other derivation.
  """

  use Ash.Resource.Change

  alias AshEnterprise.BusinessEvents
  alias AshEnterprise.BusinessEvents.Recorder

  @impl true
  def change(changeset, _opts, _context) do
    if BusinessEvents.emit?() do
      Ash.Changeset.after_action(changeset, fn _changeset, scope -> record(scope) end)
    else
      changeset
    end
  end

  defp record(scope) do
    case Recorder.shredded(scope) do
      {:ok, _tombstones} -> {:ok, scope}
      {:error, _} = error -> error
    end
  end
end
