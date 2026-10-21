defmodule AshEnterpriseWeb.A2ui.TaskBoardUI do
  @moduledoc """
  My tasks: every process task waiting on the signed-in person, as a board —
  **Open** (claimable by the person or one of their teams) and **Claimed**.

  * **Claim task** takes an open task. Offered while the task is open.
  * **Complete task** decides a task the person holds: a picker of outcomes
    and an optional comment. Only an outcome the task's step declares is
    accepted (`AshEnterprise.Bpmn.Outcomes`); a steward-decision task's
    outcome is recorded as the verdict on its match candidate
    (`AshEnterprise.Mdm.StewardTask`).
  * **Delegate task** hands a task the person holds to another of its
    candidates, picked from the people the engine would accept
    (`HumanTask.delegate_candidates`, read for that card's task alone).

  Complete and Delegate show only on the cards the person holds
  (`claimed_by_me`). Every button runs the task's own action as the clicking
  person (`AshEnterprise.Bpmn.Actions.WorkTask`), and the process engine
  decides who may claim, complete or delegate (`AshBpmn.Candidacy`). The
  board reads `HumanTask.awaiting_me` — the engine's candidacy read, oldest
  first — the read Approvals uses; a person reads the tasks on it through
  their candidacy (`AshEnterprise.Security.Checks.TaskCandidacy`). Each
  card's Select opens its task, with the outcomes its step declares, in the
  detail beside the board.

  Served at `/app/tasks` (it replaces ash_bpmn's TaskListLive there).
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Bpmn.HumanTask)
    surface_id("tasks")
    title("My tasks")
    record_label("task")

    context :task do
      resource(AshEnterprise.Bpmn.HumanTask)
      picker(false)
    end

    component :table, :board do
      display(:board)
      fields([:name, :subject_label, :assignee_label, :waiting_since])
      read_action(:awaiting_me)
      row_actions([:claim_task, :complete_task, :delegate_task])
      select_context(:task)

      row_layout do
        title(:name)
        meta([:subject_label, :assignee_label, :waiting_since])
      end

      sections do
        scope_by(:status)
        values([:open, :claimed])
        labels(open: "Open", claimed: "Claimed")
      end
    end

    component :detail, :task_detail do
      context(:task)

      fields([
        :name,
        :status,
        :subject_label,
        :declared_outcomes,
        :waiting_since,
        :assignee_label,
        :subject_detail
      ])
    end

    action :claim_task do
      label("Claim task")
      visible_when(status: :open)
      refreshes([:board])
    end

    action :complete_task do
      label("Complete task")
      visible_when(status: :claimed, claimed_by_me: true)
      prompt_fields([:outcome, :comment])
      prompt_title("Complete — the outcome, and a note for the record (optional)")
      refreshes([:board])
    end

    action :delegate_task do
      label("Delegate task")
      visible_when(status: :claimed, claimed_by_me: true)
      prompt_fields([:delegate_to_id])
      prompt_title("Delegate — the person taking it over")
      refreshes([:board])

      # Per card: only the people this task may be handed to, read as the
      # clicking person (who holds it) — never every user they can see.
      prompt_options :delegate_to_id do
        read_action(:delegate_candidates)
        record_argument(:task_id)
      end
    end

    field :name do
      label("Step")
    end

    field :delegate_to_id do
      label("Delegate to")
      relationship(:delegate_candidates)
      option_label(:email)
    end

    field :declared_outcomes do
      label("This step's outcomes")
    end

    field :subject_label do
      label("About")
      link({:record, :subject_ref})
    end

    field :assignee_label do
      label("Claimed by")
      link({:users, :assignee_id})
    end

    field :waiting_since do
      label("Waiting since")
    end

    field :subject_detail do
      label("Details")
    end
  end
end
