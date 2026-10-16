defmodule AshEnterpriseWeb.A2ui.TaskBoardUI do
  @moduledoc """
  My tasks: every process task waiting on the signed-in person, as a board —
  **Open** (claimable by the person or one of their teams) and **Claimed**.

  * **Claim task** takes an open task. Offered while the task is open; the
    action checks the person is a candidate.
  * **Complete task** decides a task the person holds, with an outcome and
    an optional comment.
  * **Delegate task** hands a task the person holds to someone else, by
    email.

  Complete and Delegate show only on the cards the person holds
  (`claimed_by_me`). Every button runs the task's own action as the
  clicking person (`AshEnterprise.Bpmn.Actions.WorkTask`): read under their
  policies, checked against the materialised candidacy, written by the
  process engine. The board reads `HumanTask.awaiting_me`, the read
  Approvals uses.

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
      fields([:name, :status, :subject_label, :waiting_since, :assignee_label, :subject_detail])
    end

    action :claim_task do
      visible_when(status: :open)
      refreshes([:board])
    end

    action :complete_task do
      visible_when(status: :claimed, claimed_by_me: true)
      prompt_fields([:outcome, :comment])
      prompt_title("Complete — the outcome, and a note for the record (optional)")
      refreshes([:board])
    end

    action :delegate_task do
      visible_when(status: :claimed, claimed_by_me: true)
      prompt_fields([:delegate_to])
      prompt_title("Delegate — the email address of the person taking it over")
      refreshes([:board])
    end

    # A board selects nothing per card, so a card opens its task's detail
    # through its link (the deep link selects `:task`).
    field :name do
      label("Step")
      link({:tasks, :id})
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
