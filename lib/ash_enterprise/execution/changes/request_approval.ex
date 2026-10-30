defmodule AshEnterprise.Execution.Changes.RequestApproval do
  @moduledoc """
  On `request`: a row the fragment routed to `awaiting_approval` gets its approval task,
  in the same transaction (ADR 0055, "Approval binding").

  `AshBpmn.Changes.RequireApproval` reads its key, candidates, exclusions and expiry
  from static options, but `request` serves every governed target, so this change
  computes them for the row from the target's effects declaration as the fragment
  snapshotted it (`AshEnterprise.Execution.Approval.task_options/2`) and delegates, the
  way `optimistic_lock` delegates to `increment`. The key is static,
  `"invocation.approval"`: one invocation has one approval, and the engine keeps one
  live task per subject and key. No `on_complete`: the `:apply_decision` trigger applies
  the decision (`AshEnterprise.Execution.Changes.ReadApproval`).

  What the approval binds (`authorization_details`, `approval_digest`,
  `approval_expires_at`) is written by the fragment's own `request` change.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Approval

  @impl true
  def change(changeset, _opts, context) do
    if Ash.Changeset.get_attribute(changeset, :status) == :awaiting_approval do
      Ash.Resource.Change.change(
        AshBpmn.Changes.RequireApproval,
        changeset,
        Approval.task_options(
          Ash.Changeset.get_attribute(changeset, :target),
          Ash.Changeset.get_attribute(changeset, :effects)
        ),
        context
      )
    else
      changeset
    end
  end
end
