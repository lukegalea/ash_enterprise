defmodule AshEnterpriseWeb.A2ui.ActionItemsUI do
  @moduledoc """
  Action items — one list of the things the signed-in person has to do
  (PROD-18): their own `Canonical.Task`s as a board, and the process tasks
  waiting on them beside it.

  * **The board** reads `Task.mine` in five lanes over `lane`: **Proposed**
    (commitments found in what they sent, and follow-ups to meetings they
    had — ADR 0047, `AshEnterprise.Canonical.Commitments`), **Inbox**
    (captured or accepted, not yet sorted), **Today**, **Later** and
    **Done**. A card moves only through the task's self-service actions —
    Accept, Dismiss, Today, Later, Done, Drop, Reopen — each run as the
    clicking person, finding the task through `:mine` first
    (`AshEnterprise.Canonical.Actions.ActOnOwnTask`), so a task that is not
    theirs is not found. A dropped or dismissed task leaves the board.
  * **Capture** is the surface's Create button: a title and an optional due
    date, through `Task.capture`, into the Inbox.
  * **Due** is the same tasks on a month or week grid by due date.
  * **Waiting on you** is `HumanTask.awaiting_me` — brief approvals, steward
    decisions and every other process task routed to the person. They are
    not copied into the list: each row links to the task itself (on My
    tasks), to what it is about, and to its run on the flight view, where it
    is decided.

  Cards show `label`: what a person typed, or a proposal's words, which are
  sealed under their source's erasure scope and read `[shredded]` after a
  shred. Every read is the person's own (`Task.mine` is self-service and
  owner-only, ADR 0052; the process tasks are read through their candidacy).

  Served at `/app/action-items` and, as the `todo` prompt, over ACP — where
  `todo <text>` captures and `done N` finishes the Nth item.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Canonical.Task
    surface_id "action_items"
    title "Action items"
    record_label "action item"
    spec_version "1.0"

    context :item do
      resource AshEnterprise.Canonical.Task
      picker false
    end

    query :lanes do
      page_size 25
      max_page_size 50
    end

    query :due_window do
      page_size 100
      max_page_size 200
    end

    component :table, :board do
      display :board
      fields [:label, :lane, :due, :source, :origin_label]
      read_action :mine
      query :lanes

      row_actions [
        :accept_mine,
        :dismiss_mine,
        :plan_today_mine,
        :plan_later_mine,
        :complete_mine,
        :drop_mine,
        :reopen_mine
      ]

      select_context :item

      row_layout do
        title :label
        meta [:due, :source, :origin_label]
      end

      sections do
        scope_by :lane
        values [:proposed, :inbox, :today, :later, :done]

        labels proposed: "Proposed",
               inbox: "Inbox",
               today: "Today",
               later: "Later",
               done: "Done"
      end
    end

    component :form do
      fields [:title, :due_at]
      create_action :capture
    end

    component :detail, :item_detail do
      context :item

      fields [
        :label,
        :lane,
        :due,
        :source,
        :origin_label,
        :evidence,
        :proposer,
        :instrument,
        :created_on
      ]
    end

    # The same tasks by due date; an undated task is on the board only.
    component :table, :due_calendar do
      fields [:label, :lane, :due]
      read_action :mine
      display :calendar
      date_field :due_at
      granularities([:month, :week])
      query :due_window
      select_context :item

      row_layout do
        title :label
        badge :lane

        badge_text proposed: "Proposed",
                   inbox: "Inbox",
                   today: "Today",
                   later: "Later",
                   done: "Done",
                   dropped: "Dropped"

        meta [:due]
      end
    end

    # The process tasks waiting on the person: linked to, never copied.
    component :table, :waiting do
      resource AshEnterprise.Bpmn.HumanTask
      fields [:subject_label, :name, :run_stage, :waiting_since]
      read_action :awaiting_me

      row_layout do
        title :subject_label
        meta [:name, :run_stage, :waiting_since]
        columns 3
      end
    end

    action :accept_mine do
      label "Accept"
      visible_when lane: :proposed
      refreshes [:board, :due_calendar]
    end

    action :dismiss_mine do
      label "Dismiss"
      visible_when lane: :proposed
      refreshes [:board, :due_calendar]
    end

    action :plan_today_mine do
      label "Today"
      visible_when lane: [:inbox, :later]
      refreshes [:board, :due_calendar]
    end

    action :plan_later_mine do
      label "Later"
      visible_when lane: [:inbox, :today]
      refreshes [:board, :due_calendar]
    end

    action :complete_mine do
      label "Done"
      visible_when lane: [:inbox, :today, :later]
      refreshes [:board, :due_calendar]
    end

    action :drop_mine do
      label "Drop"
      visible_when lane: [:inbox, :today, :later]
      refreshes [:board, :due_calendar]
    end

    action :reopen_mine do
      label "Reopen"
      visible_when lane: :done
      refreshes [:board, :due_calendar]
    end

    field :label do
      label "Action item"
    end

    field :title do
      label "Action item"
    end

    field :lane do
      label "List"
    end

    field :due do
      label "Due"
    end

    field :due_at do
      label "Due (optional)"
    end

    field :source do
      label "From"
    end

    field :evidence do
      label "In their words"
    end

    field :proposer do
      label "Proposed by"
    end

    field :instrument do
      label "Read with"
    end

    field :created_on do
      label "Captured"
    end

    # Where it came from, re-read as whoever follows the link.
    field :origin_label do
      label "Came from"
      link {:record, :origin_ref}
    end

    # -- the waiting process tasks --------------------------------------------

    # What it is about: the brief on Today, the match in the steward queue.
    field :subject_label do
      label "Waiting on you"
      link {:record, :subject_ref}
    end

    # The task itself, on My tasks, where it is claimed and decided.
    field :name do
      label "Step"
      link {:tasks, :id}
    end

    # The task's process run, on its flight view.
    field :run_stage do
      label "Where it stands"
      source [:instance, :stage_label]
      link :instance
    end

    field :waiting_since do
      label "Waiting since"
    end
  end
end
