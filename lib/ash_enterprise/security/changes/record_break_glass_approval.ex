defmodule AshEnterprise.Security.Changes.RecordBreakGlassApproval do
  @moduledoc """
  After a break-glass session's `:approve` commits, which is what makes it usable, records
  the fact in each organization of the person it acts as
  (`AshEnterprise.Automation.Occurrences.break_glass_approved/1`): `BreakGlassSession` is
  `tenant?: false`, so its own audit row lands in the chain no sweep reads, and the tenant
  whose data the session reaches is the one whose recipe should see it.

  After the transaction, not inside it: the occurrence is detective, so it can never veto
  or roll back the approval, and a failed write is logged and nothing more.
  """
  use Ash.Resource.Change

  alias AshEnterprise.Automation.Occurrences

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, session} = result ->
        Occurrences.break_glass_approved(session)
        result

      _changeset, result ->
        result
    end)
  end
end
