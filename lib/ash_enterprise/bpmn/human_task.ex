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
    task_candidate: AshEnterprise.Bpmn.TaskCandidate,
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
      cdm_entity: "Task",
      # Being asked to act on a task lets you see it and act on it: the actor's
      # candidate and held tasks, precomputed in their ActorContext, added to
      # the grant union (ADR 0009, note of 2026-10-17). It only adds;
      # maker-checker stays the engine's subtraction at candidate resolution.
      # Each act reads its task as the actor and the engine checks candidacy
      # for that task before writing anything.
      extra_grants: [
        {AshEnterprise.Security.Checks.TaskCandidacy,
         acts: [:claim_task, :complete_task, :delegate_task, :approve, :reject]}
      ]
    ]

  # --- the daily-loop surfaces (Approvals, Today; ACP `approvals`) ----------
  #
  # Which tasks wait on a person, and who may claim, complete or delegate one,
  # are the engine's answers (`AshBpmn.Candidacy`, its `:awaiting_actor` read,
  # `AshBpmn.claim_task/2`, `complete_task/2`, `delegate_task/2`). What is
  # declared here is the host's part: the surfaces' acts, the outcomes a
  # person may pick, and what a steward's decision does to its candidate.
  # Every path reads as the actor and writes through the engine — never a
  # direct write to the task or its subject.

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

    calculate :subject_ref,
              :string,
              {AshEnterprise.Bpmn.Calculations.SubjectSummary, field: :ref} do
      public? true

      description """
      The subject as a typed record reference, `<surface>:<id>` — what a
      surface links the task's subject through (the `record` link target).
      """
    end

    calculate :decided_by_label,
              :string,
              {AshEnterprise.Platform.Calculations.UserLabel, field: :decided_by_id} do
      public? true
      description "Who decided the task, by email (as the reader may see users)."
    end

    calculate :assignee_label,
              :string,
              {AshEnterprise.Platform.Calculations.UserLabel, field: :assignee_id} do
      public? true
      description "Who claimed the task, by email."
    end

    # The board's `visible_when` key for Complete / Delegate: only the
    # person holding a claimed task acts on it. UX only — the engine checks
    # the holder again (`AshBpmn.Candidacy.holds?/2`).
    calculate :claimed_by_me,
              :boolean,
              expr(
                status == :claimed and assignee_type == :user and not is_nil(^actor(:id)) and
                  assignee_id == ^actor(:id)
              ) do
      public? true
      description "Whether the reader holds this claimed task."
    end

    calculate :declared_outcomes,
              {:array, :string},
              AshEnterprise.Bpmn.Calculations.DeclaredOutcomes do
      public? true

      description """
      The outcomes the task's step declares, read from its pinned definition
      wherever it lives (a platform baseline included); nil when it declares none.
      """
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
    # The engine's candidacy read (`:awaiting_actor`), oldest first, so a
    # numbered list stays stable between reads ("approve 1").
    read :awaiting_me do
      description "The engine's `:awaiting_actor` (open tasks the actor or one of their teams is a candidate for, claimed tasks they hold, none that excludes them), oldest first."
      prepare AshBpmn.Resources.HumanTask.AwaitingActor
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    action :claim_task, :string do
      description """
      Claim an open task the actor (or one of their teams) is a candidate
      for, through the process engine.
      """

      argument :record_id, :uuid, allow_nil?: false
      run {AshEnterprise.Bpmn.Actions.WorkTask, op: :claim}
    end

    action :complete_task, :string do
      description """
      Complete a task the actor holds with one of the outcomes its step
      declares, through the process engine (`AshBpmn.complete_task/2`); a
      steward-decision task records the verdict on its match candidate.
      """

      argument :record_id, :uuid, allow_nil?: false

      # A picker on the board (an enumerated argument is a ChoicePicker): the
      # outcomes the checked-in baselines declare. The action accepts only
      # the ones this task's step declares (`AshEnterprise.Bpmn.Outcomes`).
      argument :outcome, :atom,
        allow_nil?: false,
        constraints: [one_of: AshEnterprise.Bpmn.Outcomes.offered_atoms()]

      argument :comment, :string, allow_nil?: true, constraints: [max_length: 2000]
      run {AshEnterprise.Bpmn.Actions.WorkTask, op: :complete}
    end

    action :delegate_task, :string do
      description """
      Hand a task the actor holds to another of its candidates, by their
      email address, through the process engine (`AshBpmn.delegate_task/2`).
      """

      argument :record_id, :uuid, allow_nil?: false
      argument :delegate_to, :ci_string, allow_nil?: false, constraints: [max_length: 320]
      run {AshEnterprise.Bpmn.Actions.WorkTask, op: :delegate}
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
