defmodule AshEnterprise.Bpmn.TaskCandidate do
  @moduledoc """
  Who may act on a task, materialised as rows.

  The reason the task list is one indexed query rather than a policy evaluation per row, and
  the reason maker-checker can be expressed by *subtraction at candidate resolution* rather
  than as a `forbid_if` — which would break the additive grant model
  [thesis 3](../../docs/manifesto/03-authorization-is-data.md) rests on.

  Not audited: candidacy is a set, computed from the role model at task creation. The
  interesting event is the task being created or decided, and both of those are audited on
  `AshEnterprise.Bpmn.HumanTask`.
  """

  use AshBpmn.Resources.TaskCandidate,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_task_candidates",
    task: AshEnterprise.Bpmn.HumanTask,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      lifecycle?: false,
      audit?: false,
      archival?: false
    ]
end
