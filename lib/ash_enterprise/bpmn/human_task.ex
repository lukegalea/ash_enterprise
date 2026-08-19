defmodule AshEnterprise.Bpmn.HumanTask do
  @moduledoc """
  A work item waiting on a person: an approval, a review, a decision someone has to make.

  This is the resource ADR 0009 was written about. Sitting it on the platform base resource is
  what makes an approval an ordinary owned, tenant-scoped, audited record rather than a row in
  a workflow engine's private schema — so the answer to *who may approve this* comes from the
  same union of grants as the answer to *who may read this*, and there is no second security
  model to keep in step.

  Audited, and it is the most important audit row in the domain: who claimed it, who decided
  it, what they decided, and who delegated it to them.
  """

  use AshBpmn.Resources.HumanTask,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_human_tasks",
    instance: AshEnterprise.Bpmn.Instance,
    token: AshEnterprise.Bpmn.Token,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      # User-owned rather than organization-owned: a task has an assignee, and ownership is
      # how the platform's grant model already expresses "this record is that person's".
      ownership: :user_owned,
      # `open -> claimed -> completed | cancelled` is the task's own state machine.
      lifecycle?: false,
      audit?: true,
      archival?: false,
      cdm_entity: "Task"
    ]
end
