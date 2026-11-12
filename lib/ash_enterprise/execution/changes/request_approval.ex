defmodule AshEnterprise.Execution.Changes.RequestApproval do
  @moduledoc """
  On `request`: a row the fragment routed to `awaiting_approval` gets its approval task,
  in the same transaction (ADR 0055, "Approval binding").

  `AshBpmn.Changes.RequireApproval` reads its key, candidates, exclusions and expiry
  from static options, but `request` serves every governed target, so this change
  computes them for the row from the posture in force and the target's effects
  declaration as the fragment snapshotted it
  (`AshEnterprise.Execution.Approval.task_options/1`, which asks the package's
  rule, `AshAgent.Invocation.Approval.rule/2`) and delegates, the
  way `optimistic_lock` delegates to `increment`. The key is static,
  `"invocation.approval"`: one invocation has one approval, and the engine keeps one
  live task per subject and key. No `on_complete`: the `:apply_decision` trigger applies
  the decision (`AshEnterprise.Execution.Changes.ReadApproval`).

  What an approval binds (`authorization_details`, `approval_digest`,
  `approval_expires_at`) is written by the fragment's own `request` change, which runs
  ahead of this one, so the attributes it stamped are read as the row it will have
  written.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Execution.Invocation

  @impl true
  def change(changeset, _opts, context) do
    if Ash.Changeset.get_attribute(changeset, :status) == :awaiting_approval do
      Ash.Resource.Change.change(
        AshBpmn.Changes.RequireApproval,
        changeset,
        Approval.task_options(as_written(changeset)),
        context
      )
    else
      changeset
    end
  end

  # The request as it will be written: what the fragment's `request` change has
  # already stamped on the changeset, enough for the rule
  # (`AshAgent.Invocation.Approval.rule/2`) and the task's options, and nothing
  # that needs the row to exist.
  defp as_written(changeset) do
    %Invocation{
      target: Ash.Changeset.get_attribute(changeset, :target),
      effects: Ash.Changeset.get_attribute(changeset, :effects),
      approval_mode: Ash.Changeset.get_attribute(changeset, :approval_mode),
      executing_principal: Ash.Changeset.get_attribute(changeset, :executing_principal),
      owner_id: Ash.Changeset.get_attribute(changeset, :owner_id),
      organization_id: changeset.tenant
    }
  end
end
