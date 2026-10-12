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
      # Organization-owned, not user-owned, and the reason is the thing that makes this design
      # work rather than a technicality.
      #
      # `:user_owned` gives a non-null `owner_id`, and **a task has no owner until someone
      # claims it**. An open approval is deliberately unassigned: that is what makes it
      # claimable by any of its candidates, and the whole point of materialising a candidate
      # list is that "who may act on this" is a set rather than a person. Modelling it as owned
      # would force the engine to invent an owner at creation, which is either the requester
      # (wrong -- maker-checker excludes them) or an arbitrary candidate (wrong -- it is not
      # theirs yet).
      #
      # So access is governed by `TaskCandidate` rows, which is the mechanism
      # `docs/manifesto/03-authorization-is-data.md` argues for, and `assignee_id` records who
      # took it once somebody has.
      #
      # Found by building it: a task on the privileged path could not be created at all, and
      # the process rolled back with no error surfaced.
      ownership: :organization_owned,
      # `open -> claimed -> completed | cancelled` is the task's own state machine.
      lifecycle?: false,
      audit?: true,
      archival?: false,
      cdm_entity: "Task"
    ]

  # --- the daily-loop surfaces (Approvals, Today; ACP `approvals`) ----------
  #
  # Declared here, on the host's task resource, rather than in ash_bpmn: which
  # tasks are "mine" and how a person decides one from a surface is host
  # policy. Every path below reads as the actor and decides through
  # `AshBpmn.complete_task/2` — never a direct write to the task or subject.

  relationships do
    has_many :candidates, AshEnterprise.Bpmn.TaskCandidate do
      destination_attribute :task_id
      description "Who may act on this task, materialised as rows."
    end
  end

  calculations do
    calculate :subject_label,
              :string,
              {AshEnterprise.Bpmn.Calculations.SubjectSummary, field: :label} do
      public? true
      description "What the task is about: `Morning brief · Mon 12 Oct`, or the subject's kind."
    end

    calculate :subject_outline,
              :string,
              {AshEnterprise.Bpmn.Calculations.SubjectSummary, field: :outline} do
      public? true
      description "The subject in one line — a morning brief's event count and span."
    end

    calculate :subject_detail,
              :string,
              {AshEnterprise.Bpmn.Calculations.SubjectSummary, field: :detail} do
      public? true
      description "The subject's content for the decider — a morning brief's draft."
    end

    calculate :waiting_since,
              :string,
              {AshEnterprise.Platform.Calculations.LocalStamp,
               field: :inserted_at, relative?: true} do
      public? true
      description "When the task opened, on the operator's wall clock."
    end
  end

  actions do
    read :awaiting_me do
      description "Open or claimed tasks the actor (or one of their teams) is a candidate for, oldest first."
      prepare AshEnterprise.Bpmn.Preparations.AwaitingActor
    end

    action :approve, :string do
      description """
      Decide a task the actor is a candidate for with outcome `approved`,
      through the process engine (`AshBpmn.complete_task/2`).
      """

      argument :record_id, :uuid, allow_nil?: false
      argument :comment, :string, allow_nil?: true, constraints: [max_length: 2000]
      run {AshEnterprise.Bpmn.Actions.DecideTask, outcome: "approved"}
    end

    action :reject, :string do
      description """
      Decide a task the actor is a candidate for with outcome `rejected`,
      through the process engine (`AshBpmn.complete_task/2`).
      """

      argument :record_id, :uuid, allow_nil?: false
      argument :comment, :string, allow_nil?: true, constraints: [max_length: 2000]
      run {AshEnterprise.Bpmn.Actions.DecideTask, outcome: "rejected"}
    end
  end
end
