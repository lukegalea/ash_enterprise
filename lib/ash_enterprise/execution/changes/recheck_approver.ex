defmodule AshEnterprise.Execution.Changes.RecheckApprover do
  @moduledoc """
  On `claim`: the person who approved the row must still be able to approve it, at
  every claim (ADR 0055, "Approval binding"). An approval is provenance, not an
  exemption: if the approver has since lost the approver role, left the tenant or been
  deactivated (`AshEnterprise.Execution.Approval.approver_holds?/2`, from a freshly
  built `ActorContext`), the row becomes `stale` with `error_code`
  `"approver_unauthorized"`, and nothing runs.

  Runs inside the claim's transaction, after the fragment's own re-check of what the
  approval binds (expiry, digest, subject and target), and only on a claim that is
  about to start work. Claim logic, not a policy check, so it reads.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Approval

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &recheck/1)
  end

  defp recheck(changeset) do
    row = changeset.data

    if Ash.Changeset.get_attribute(changeset, :status) == :executing and
         row.approval_mode != :none and not Approval.approver_holds?(row, row.approved_by_id) do
      changeset
      |> AshStateMachine.transition_state(:stale)
      |> Ash.Changeset.force_change_attributes(%{
        error_code: "approver_unauthorized",
        lease_expires_at: nil,
        attempt_count: row.attempt_count,
        next_attempt_at: nil
      })
    else
      changeset
    end
  end
end
