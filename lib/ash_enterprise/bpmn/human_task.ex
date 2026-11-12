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
    # Without its own engine bypass: the platform's, narrowed by `EngineReach`, is the
    # engines' only one, so nothing they mark reaches a human_only action (ADR 0059).
    policies?: false,
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
         acts: [
           :claim_task,
           :complete_task,
           :delegate_task,
           :approve,
           :reject,
           :request_info,
           :resolve,
           :settle,
           :answer
         ]}
      ],
      # Deciding is a person's act (ADR 0055, "Approval binding"): neither engine
      # bypass nor a system actor reaches these doors; a candidate's grant does.
      human_only: [:approve, :reject, :request_info, :resolve, :settle, :answer],
      extra_extensions: [AshAgent.Effects, AshAi]
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

  relationships do
    # Whom the task may be handed to (`User.delegate_candidates`): the
    # destination of the board's Delegate picker, whose options are read per
    # task through that action.
    has_many :delegate_candidates, AshEnterprise.Accounts.User do
      public? true
      manual AshEnterprise.Bpmn.Relationships.DelegateCandidates
      description "The people the actor may hand this task to; nobody unless they hold it."
    end
  end

  calculations do
    # The review packet of an invocation's approval task
    # (`AshEnterprise.Execution.ReviewPacket`); nil on every other task.
    calculate :review_target,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :target} do
      public? true
      description "The action an invocation approval would let run, and its declared effects."
    end

    calculate :review_arguments,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :arguments} do
      public? true
      description "The request's arguments, named and typed by the target's input schema."
    end

    calculate :review_digest,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :digest} do
      public? true
      description "The approval digest a decision on this task binds."
    end

    calculate :review_currency,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :currency} do
      public? true

      description "Whether approving would still decide what was asked: current, stale (and why), decided or unknown."
    end

    calculate :review_evidence,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :evidence} do
      public? true

      description "References to what the request rests on: the subject's version, the work it belongs to, observations."
    end

    calculate :review_decision,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :decision} do
      public? true
      description "The decisions evaluated for the request, with the rules that matched."
    end

    calculate :due_label,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :due} do
      public? true
      description "When the task is due and when the approval window closes."
    end

    calculate :escalation_label,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :escalation} do
      public? true
      description "What the engine recorded about escalating the task."
    end

    calculate :routing_label,
              :string,
              AshEnterprise.Bpmn.Calculations.RoutingLabel do
      public? true

      description "Set when the task's candidates were all excluded: who it went to instead, or that nobody can act on it."
    end

    calculate :info_exchange,
              :string,
              {AshEnterprise.Bpmn.Calculations.ReviewPacket, field: :questions} do
      public? true
      description "An approver's questions to the requester, and the answers."
    end

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

    # Stalled reviews: what the stalled-reviews surface and the assistant's
    # `stalled_reviews` tool both read, so the chat and the page show one set.
    read :stalled do
      description "Open and claimed tasks the reader may read that opened more than two days ago, oldest first."
      filter expr(status in [:open, :claimed] and inserted_at < ago(2, :day))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    # The review tasks an audit package reports for a period
    # (`AshEnterprise.Audit.Package.Build`): every task that existed during it and
    # was opened, claimed, decided or cancelled within it, oldest first.
    read :touched_between do
      description "Tasks opened before `to` and last changed at or after `from`, oldest first."
      argument :from, :utc_datetime_usec, allow_nil?: false
      argument :to, :utc_datetime_usec, allow_nil?: false
      filter expr(inserted_at < ^arg(:to) and updated_at >= ^arg(:from))
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
      Hand a task the actor holds to another of its candidates, through the
      process engine (`AshBpmn.delegate_task/2`). The board's picker offers
      the task's `delegate_candidates`.
      """

      argument :record_id, :uuid, allow_nil?: false
      argument :delegate_to_id, :uuid, allow_nil?: false
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

    action :request_info, :string do
      description """
      Ask the person who made a request for more information before deciding it: the
      approval task completes as `request_info`, the request waits, and the requester is
      asked your question. Only an invocation's approval task asks
      (`AshEnterprise.Execution.InfoRequest`).
      """

      argument :record_id, :uuid, allow_nil?: false

      argument :question, :string,
        allow_nil?: false,
        constraints: [max_length: 2000],
        description: "What you need to know, as the requester will read it."

      run {AshEnterprise.Bpmn.Actions.DecideTask, outcome: "request_info"}
    end

    action :resolve, :string do
      description """
      Settle an invocation whose outcome is unknown, saying why: it `succeeded` (it
      happened), it `failed` (it did not, and is not tried again), or `retry` (it did not
      happen, you checked, and it runs again under the same request). Recorded as the
      recovery surface's settlement, with who and why
      (`AshEnterprise.Execution.Intervention`). Only a resolution task
      (`AshEnterprise.Execution.Resolution`) is resolved.
      """

      argument :record_id, :uuid, allow_nil?: false

      # A picker on the board (an enumerated argument is a ChoicePicker), of
      # exactly the three outcomes a resolution task has.
      argument :outcome, :atom,
        allow_nil?: false,
        constraints: [one_of: [:succeeded, :failed, :retry]]

      argument :comment, :string,
        allow_nil?: false,
        constraints: [max_length: 2000],
        description: "Why: what you checked, in your own words."

      run AshEnterprise.Bpmn.Actions.SettleTask
    end

    # The decision on the task itself, made only inside `Intervention.resolve`, which
    # records it: a resolution task is decided only here, and no surface offers it.
    action :settle, :string do
      description """
      Decide a resolution task with `succeeded`, `failed` or `retry`, for
      `AshEnterprise.Execution.Intervention`'s `resolve`, which records the act. People
      settle through `resolve`.
      """

      public? false

      argument :record_id, :uuid, allow_nil?: false

      argument :outcome, :atom,
        allow_nil?: false,
        constraints: [one_of: [:succeeded, :failed, :retry]]

      argument :comment, :string, allow_nil?: false, constraints: [max_length: 2000]
      run {AshEnterprise.Bpmn.Actions.DecideTask, outcome: :from_argument}
    end

    action :answer, :string do
      description """
      Answer a question you were asked: an agent's (`AshEnterprise.Execution.HumanInput`),
      whose run carries on with your answer, or an approver's about your request
      (`AshEnterprise.Execution.InfoRequest`), which then goes back to them. The task
      completes as `answered`. Only a question is answered, and a question is completed
      only here.
      """

      argument :record_id, :uuid, allow_nil?: false
      argument :answer, :string, allow_nil?: false, constraints: [max_length: 2000]
      run {AshEnterprise.Bpmn.Actions.DecideTask, outcome: "answered"}
    end
  end

  # A decision through ACP or a surface asks first (ADR 0057): the person
  # confirms the exact task before it is recorded. It is final, so the hints
  # keep MCP's cautious defaults.
  effects do
    action :approve, kind: :execute, open_world?: false, approval: :confirm, intent: :approve
    action :reject, kind: :execute, open_world?: false, approval: :confirm, intent: :approve
    action :request_info, kind: :execute, open_world?: false, approval: :confirm, intent: :approve
    action :resolve, kind: :execute, open_world?: false, approval: :confirm, intent: :approve
    action :answer, kind: :execute, open_world?: false, approval: :confirm, intent: :approve
  end

  # The assistant's names for a decision (`AshEnterprise.Assistant.Agent`): asking for
  # one is a request the person confirms on screen, and it runs as them.
  tools do
    tool :approve_task, :approve do
      description """
      Ask to approve a task waiting on the person's decision, by its id from
      pending_approvals. Nothing is decided until they confirm on screen.
      """
    end

    tool :reject_task, :reject do
      description """
      Ask to reject a task waiting on the person's decision, by its id from
      pending_approvals. Nothing is decided until they confirm on screen.
      """
    end
  end
end
