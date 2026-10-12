defmodule AshEnterpriseWeb.A2ui.TodayUI do
  @moduledoc """
  Today — the operator's home for the day (Productivity OS dogfood, epic E6).

  Anchored on the latest `MorningBrief`: its draft is rendered on read, and
  its Approve / Reject row actions are delegated (`via`) to
  `AshEnterprise.Agents.BriefDecision`, which decides the brief's BPMN
  approval task as the actor — the process records the outcome, nothing here
  writes the brief. Two reports frame it: today's agenda and the day's pulse
  (approvals waiting, next event, sync health, inbox), both ordinary reads as
  the actor (`AshEnterprise.Agents.Today`). The web host runs them on mount.

  Served at `/app/today` and, as the `today` prompt, over ACP.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Agents.MorningBrief
    surface_id "today"
    title "Today"
    record_label "morning brief"
    spec_version "1.0"

    component :table, :brief do
      fields [:headline, :status, :summary]
      read_action :latest
      row_actions [:approve, :reject]

      row_layout do
        title :headline
        badge :status

        badge_text pending_approval: "Waiting for your approval",
                   approved: "Approved",
                   rejected: "Rejected"

        meta [:summary]
        columns 1
      end
    end

    component :report, :agenda do
      action :agenda
      fields [:time, :title, :where, :status]
    end

    component :report, :pulse do
      action :pulse
      fields [:signal, :value]
    end

    action :approve do
      via {AshEnterprise.Agents.BriefDecision, :decide, ["approved"]}
      visible_when status: :pending_approval
    end

    action :reject do
      via {AshEnterprise.Agents.BriefDecision, :decide, ["rejected"]}
      visible_when status: :pending_approval
    end

    field :headline do
      label "Morning brief"
    end

    field :summary do
      label "Outline"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.CalendarUI do
  @moduledoc """
  Calendar — the agenda by window: today (the default), tomorrow, this week
  or the next two weeks, each a named preset over its own `CalendarEvent`
  read, cut in the operator's display zone; filterable by status. Read-only.

  Served at `/app/calendar` and, as the `calendar` prompt, over ACP.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Canonical.CalendarEvent
    surface_id "calendar"
    title "Calendar"
    record_label "event"
    spec_version "1.0"

    # One agenda, three windows: the window is a named preset (the read
    # action behind it is cut in the display zone), so switching days is a
    # query, not a page — and the client only ever names the window.
    query :agenda do
      filters [:status]
      default_preset :today
      page_size 50
      max_page_size 200

      preset :today do
        read_action :today
      end

      preset :tomorrow do
        read_action :tomorrow
      end

      preset :this_week do
        read_action :this_week
      end

      preset :upcoming do
        read_action :upcoming
      end
    end

    component :table do
      fields [:title, :status, :when, :location, :organizer_label]
      read_action :today
      query :agenda

      row_layout do
        title :title
        badge :status
        badge_text confirmed: "Confirmed", tentative: "Tentative", cancelled: "Cancelled"
        meta [:when, :location, :organizer_label]
        columns 3
      end
    end

    field :title do
      label "Event"
    end

    field :when do
      label "When"
    end

    field :location do
      label "Where"
    end

    field :organizer_label do
      label "Organizer"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.PeopleUI do
  @moduledoc """
  People — the canonical people directory: search by name or address, and a
  person's detail with the events they organize (on the operator's wall
  clock). Read-only; people are projected, never typed in here.

  Served at `/app/people` and, as the `people` prompt, over ACP.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Canonical.Person
    surface_id "people"
    title "People"
    record_label "person"
    spec_version "1.0"

    # Both ways in: search the picker, or (where the grid offers it) a row's
    # View button. Either fills the detail beside the directory.
    context :person do
      resource AshEnterprise.Canonical.Person
      label "Open a person"
      option_label :name
      option_search [:name, :email]
      option_limit 25
    end

    query :directory do
      search_fields [:name, :email]
      sortable [:name, :email, :organized_event_count]
      default_sort name: :asc
      page_size 25
      max_page_size 100
    end

    component :table do
      fields [:label, :email, :next_event, :organized_event_count]
      read_action :read
      query :directory
      select_context :person

      row_layout do
        title :label
        meta [:email, :next_event, :organized_event_count]
        columns 3
      end
    end

    component :detail, :person_detail do
      context :person
      fields [:label, :email, :next_event, :organized_event_count, :events_text]
    end

    field :next_event do
      label "Next event"
    end

    field :label do
      label "Name"
    end

    field :email do
      label "Email"
    end

    field :organized_event_count do
      label "Events organized"
    end

    field :events_text do
      label "Their events"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.InboxUI do
  @moduledoc """
  Inbox — Gmail threads from the canonical model, newest activity first, with
  a thread's latest messages in its detail. Search reaches correspondents by
  name or address (subjects and bodies are sealed under their account's
  erasure scope, so the database cannot search them).

  Empty until the Gmail zone gate admits content (ADR 0042); the host says
  which kind of empty it is (`AshEnterprise.Canonical.Admission`). Never reads
  `SourceObject`.

  Served at `/app/inbox` and, as the `inbox` prompt, over ACP.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Canonical.Conversation
    surface_id "inbox"
    title "Inbox"
    record_label "Gmail thread"
    spec_version "1.0"

    context :thread do
      resource AshEnterprise.Canonical.Conversation
      picker false
    end

    query :threads do
      search_fields [[:messages, :sender, :name], [:messages, :sender, :email]]
      sortable [:last_message_at, :message_count]
      default_sort last_message_at: :desc
      page_size 25
      max_page_size 100
    end

    component :table do
      fields [:subject, :latest_message, :last_activity, :message_count]
      read_action :gmail
      query :threads
      select_context :thread

      row_layout do
        title :subject
        meta [:latest_message, :last_activity, :message_count]
        columns 3
      end
    end

    component :detail, :thread_detail do
      context :thread
      fields [:subject, :last_activity, :message_count, :messages_text]
    end

    field :latest_message do
      label "Latest"
    end

    field :last_activity do
      label "Last activity"
    end

    field :message_count do
      label "Messages"
    end

    field :messages_text do
      label "Latest messages"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.SlackUI do
  @moduledoc """
  Slack — Slack conversations from the canonical model, newest activity
  first, each labelled by kind (channel, private channel, group DM, DM — from
  the conversation's `kind` once the projection records it), with a
  conversation's latest messages in its detail. Search reaches senders by
  name or address.

  Empty until the Slack zone gate admits content (ADR 0042); the host says
  which kind of empty it is (`AshEnterprise.Canonical.Admission`). Never reads
  `SourceObject`.

  Served at `/app/slack` and, as the `slack` prompt, over ACP.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Canonical.Conversation
    surface_id "slack"
    title "Slack"
    record_label "Slack conversation"
    spec_version "1.0"

    context :conversation do
      resource AshEnterprise.Canonical.Conversation
      picker false
    end

    query :conversations do
      search_fields [[:messages, :sender, :name], [:messages, :sender, :email]]
      sortable [:last_message_at, :message_count]
      default_sort last_message_at: :desc
      page_size 25
      max_page_size 100
    end

    component :table do
      fields [:subject, :kind_label, :latest_message, :last_activity, :message_count]
      read_action :slack
      query :conversations
      select_context :conversation

      row_layout do
        title :subject
        badge :kind_label
        meta [:latest_message, :last_activity, :message_count]
        columns 3
      end
    end

    component :detail, :conversation_detail do
      context :conversation
      fields [:subject, :kind_label, :last_activity, :message_count, :messages_text]
    end

    field :kind_label do
      label "Kind"
    end

    field :subject do
      label "Conversation"
    end

    field :latest_message do
      label "Latest"
    end

    field :last_activity do
      label "Last activity"
    end

    field :message_count do
      label "Messages"
    end

    field :messages_text do
      label "Latest messages"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.ApprovalsUI do
  @moduledoc """
  Approvals — the human tasks waiting on the actor (or one of their teams),
  oldest first, with what each is about. Approve / Reject decide the task
  through the process engine (`HumanTask.approve` / `.reject`, which check
  candidacy first); Reject asks for an optional comment.

  Served at `/app/approvals` and, as the `approvals` prompt, over ACP —
  where `approve N` / `reject N` surface as permission requests.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Bpmn.HumanTask
    surface_id "approvals"
    title "Approvals"
    record_label "approval"
    spec_version "1.0"

    context :task do
      resource AshEnterprise.Bpmn.HumanTask
      picker false
    end

    component :table do
      fields [:subject_label, :status, :subject_outline, :name, :waiting_since]
      read_action :awaiting_me
      row_actions [:approve, :reject]
      select_context :task

      row_layout do
        title :subject_label
        badge :status
        badge_text open: "Open", claimed: "Claimed"
        meta [:subject_outline, :name, :waiting_since]
        columns 2
      end
    end

    component :detail, :task_detail do
      context :task
      fields [:subject_label, :name, :status, :waiting_since, :subject_detail]
    end

    action :reject do
      prompt_fields [:comment]
      prompt_title "Reject — add a note for the record (optional)"
    end

    field :subject_label do
      label "About"
    end

    field :subject_outline do
      label "Outline"
    end

    field :name do
      label "Step"
    end

    field :waiting_since do
      label "Waiting since"
    end

    field :subject_detail do
      label "Details"
    end
  end
end
