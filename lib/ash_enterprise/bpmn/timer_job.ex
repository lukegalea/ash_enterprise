defmodule AshEnterprise.Bpmn.TimerJob do
  @moduledoc """
  The timer ledger: one row per timer the engine armed, and how it ended —
  `AshBpmn.Resources.TimerJob` instantiated on the platform base.

  Oban is the scheduler and stays the scheduler. This row is the record Oban cannot keep: the
  pruner deletes finished jobs within days, and a cancelled job carries no reason. The row
  says which task, token and node the timer was for, its kind, the instant it was armed for
  (a fact from the moment it is armed, even when the diagram computed it from data), the job
  that carried it, and how it ended, with a `cancel_reason` when it was called off. "Why did
  this escalation never fire?" is answered here a month later (ash_bpmn DESIGN.md §11.3).

  Without this resource installed the engine still runs timers, but a rescheduled or claimed
  timer has no row to be cancelled on, and the forensic question has no answer.

  **Not audited, deliberately**, like `AshEnterprise.Bpmn.Dispatch`: the row is already the
  record of the timer, written and closed by the engine. Auditing it would be a second copy of
  the same fact, and two logs of one fact eventually disagree. Each timer's firing is also a
  `:timer_fired` `AshEnterprise.Bpmn.ProcessEvent`.

  Written by the engine alone (`engine_only`): no person arms, fires or cancels a ledger row.
  Reading it follows the organization's grants, as every organization-owned record does.
  """

  use AshBpmn.Resources.TimerJob,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_timer_jobs",
    # Without its own engine bypass: the platform's, narrowed by `EngineReach`, is the
    # engines' only one, so nothing they mark reaches a human_only action (ADR 0059).
    policies?: false,
    instance: AshEnterprise.Bpmn.Instance,
    token: AshEnterprise.Bpmn.Token,
    task: AshEnterprise.Bpmn.HumanTask,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      lifecycle?: false,
      # The ledger is the record; see the moduledoc.
      audit?: false,
      archival?: false,
      engine_only: [:create, :attach_job, :record_fired, :record_cancelled]
    ]
end
