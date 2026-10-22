defmodule AshEnterpriseWeb.A2ui.TodayUI do
  @moduledoc """
  Today — the operator's home for the day (Productivity OS dogfood, epic E6).

  Anchored on the latest `MorningBrief`: its draft is rendered on read, its
  detail links the events it covers and its approval task, and its Approve /
  Reject row actions are delegated (`via`) to
  `AshEnterprise.Agents.BriefDecision`, which decides the brief's BPMN
  approval task as the actor — the process records the outcome, nothing here
  writes the brief. Two reports frame it: today's agenda and the day's pulse
  (approvals waiting, action items, next event, sync health, inbox), both
  ordinary reads as the actor (`AshEnterprise.Agents.Today`). The web host
  runs them on mount. Between them, the day's action items: the person's own
  open tasks planned for today or due by tonight (`Task.due_today`), each a
  link to its card on Action items.

  Served at `/app/today` and, as the `today` prompt, over ACP.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Agents.MorningBrief
    surface_id "today"
    title "Today"
    record_label "morning brief"
    spec_version "1.0"

    # The brief opens in detail: its events and its approval, as links.
    context :brief do
      resource AshEnterprise.Agents.MorningBrief
      picker false
    end

    component :table, :brief do
      fields [:headline, :status, :summary]
      read_action :latest
      row_actions [:approve, :reject]
      select_context :brief

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

    component :detail, :brief_detail do
      context :brief
      fields [:headline, :status, :summary, :brief_events, :approval, :process_stage]
    end

    # The day's action items (PROD-18): the person's own open tasks planned
    # for today or due by tonight, each a link to it on the Action items
    # board. Read through the self-service `Task.due_today`.
    component :table, :today_items do
      resource AshEnterprise.Canonical.Task
      fields [:label, :due, :source]
      read_action :due_today

      row_layout do
        title :label
        meta [:due, :source]
        columns 2
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

    # A today item links to its card on Action items.
    field :label do
      label "Today"
      link {:action_items, :id}
    end

    field :due do
      label "Due"
    end

    field :source do
      label "From"
    end

    field :summary do
      label "Outline"
    end

    field :brief_events do
      label "Events"
      links :events
      link_label :title
    end

    field :approval do
      label "Approval"
      link :approval_task
      link_label :status
    end

    # The brief's `morning.brief` run, on its flight view.
    field :process_stage do
      label "Where it stands"
      source [:process_run, :stage_label]
      link :process_run
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.CalendarUI do
  @moduledoc """
  Calendar — a month or week grid of the person's `CalendarEvent`s, with
  the window's events (or a picked day's) listed beside it, filterable by
  status. It opens on the month; Month / Week switches the grid. Days are
  the operator's display-zone days: ash_a2ui cuts the window in
  `config :ash_a2ui, :calendar_time_zone`, which is
  `AshEnterprise.Platform.LocalTime.zone/0`.

  The agenda windows stay as quick ranges: today, tomorrow, this week and
  the next two weeks are presets over their own reads (cut in the display
  zone, `AshEnterprise.Canonical.Preparations.AgendaWindow`). Choosing one
  moves the grid to the window it starts in (`calendar_anchor`) and
  narrows the grid and the list to that range; "All" shows every event of
  the window. An event opens in detail with its organizer and attendees as
  links to People. Read-only.

  Served at `/app/calendar` and, as the `calendar` prompt, over ACP (where
  the window names the preset, `AshEnterprise.Acp.Commands`).
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Canonical.CalendarEvent
    surface_id "calendar"
    title "Calendar"
    record_label "event"
    spec_version "1.0"

    context :event do
      resource AshEnterprise.Canonical.CalendarEvent
      picker false
    end

    # The month is the window; the quick ranges are named presets (the read
    # behind each is cut in the display zone), so the client only ever names
    # a preset or a date. A month of events is one page.
    query :agenda do
      filters [:status]
      page_size 100
      max_page_size 200

      preset :today do
        read_action :today
        calendar_anchor(0)
      end

      preset :tomorrow do
        read_action :tomorrow
        calendar_anchor(1)
      end

      preset :this_week do
        read_action :this_week
        calendar_anchor(0)
      end

      preset :upcoming do
        read_action :upcoming
        calendar_anchor(0)
      end
    end

    component :table do
      fields [:title, :status, :when, :location, :organizer_label]
      display :calendar
      date_field :starts_at
      end_date_field :ends_at
      granularities([:month, :week])
      query :agenda
      select_context :event

      row_layout do
        title :title
        badge :status
        badge_text confirmed: "Confirmed", tentative: "Tentative", cancelled: "Cancelled"
        meta [:when, :location, :organizer_label]
        columns 3
      end
    end

    component :detail, :event_detail do
      context :event
      fields [:title, :status, :when, :location, :organizer_label, :attendee_count]
    end

    # Who is invited, and how they answered: the derived attendee joins.
    component :table, :attendees do
      resource AshEnterprise.Canonical.EventAttendee
      fields [:attendee, :response_label]
      context_filter event_id: :event
      require_context [:event]
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
      link :organizer
    end

    field :attendee_count do
      label "Invited"
    end

    field :attendee do
      label "Attendee"
      source [:person, :label]
      link :person
    end

    field :response_label do
      label "Response"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.PeopleUI do
  @moduledoc """
  People — the canonical people directory: search by name or address, and a
  person's detail with what the canonical model knows about them, as related
  tables: the events they organize and are invited to (with their answer),
  the conversations they take part in, and the messages they sent — every row
  a link to its event, thread or conversation. Read-only; people are
  projected, never typed in here.

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

    query :events do
      sortable [:starts_at]
      default_sort starts_at: :desc
      page_size 10
      max_page_size 50
    end

    query :messages do
      sortable [:sent_at]
      default_sort sent_at: :desc
      page_size 10
      max_page_size 50
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

      fields [
        :label,
        :email,
        :next_event,
        :organized_event_count,
        :conversation_count,
        :sent_message_count
      ]
    end

    component :table, :organized do
      resource AshEnterprise.Canonical.CalendarEvent
      fields [:title, :when, :status]
      query :events
      context_filter organizer_id: :person
      require_context [:person]
    end

    component :table, :invited do
      resource AshEnterprise.Canonical.EventAttendee
      fields [:invited_event, :invited_when, :response_label]
      context_filter person_id: :person
      require_context [:person]
    end

    component :table, :conversations do
      resource AshEnterprise.Canonical.ConversationParticipant
      fields [:conversation, :conversation_kind, :conversation_activity]
      context_filter person_id: :person
      require_context [:person]
    end

    component :table, :sent do
      resource AshEnterprise.Canonical.Message
      fields [:sent, :thread, :preview]
      query :messages
      context_filter sender_id: :person
      require_context [:person]
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

    field :conversation_count do
      label "Conversations"
    end

    field :sent_message_count do
      label "Messages sent"
    end

    # An organized event's row links to the event itself.
    field :title do
      label "Organizes"
      link {:calendar, :id}
    end

    field :when do
      label "When"
    end

    field :invited_event do
      label "Invited to"
      source [:event, :title]
      link :event
    end

    field :invited_when do
      label "When"
      source [:event, :when]
    end

    field :response_label do
      label "Response"
    end

    field :conversation do
      label "Takes part in"
      source [:conversation, :subject]
      link :conversation
    end

    field :conversation_kind do
      label "Kind"
      source [:conversation, :kind_label]
    end

    field :conversation_activity do
      label "Last activity"
      source [:conversation, :last_activity]
    end

    field :sent do
      label "Sent"
    end

    field :thread do
      label "In"
      source [:conversation, :subject]
      link :conversation
    end

    field :preview do
      label "Message"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.InboxUI do
  @moduledoc """
  Inbox — Gmail threads from the canonical model, newest activity first. A
  thread opens in detail with its people (links to People) and its messages
  as a related table, each sender a link. Search reaches correspondents by
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

    query :messages do
      sortable [:sent_at]
      default_sort sent_at: :asc
      page_size 50
      max_page_size 200
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
      fields [:subject, :last_activity, :message_count, :people]
    end

    # The thread's messages, oldest first, each sender a link to People.
    component :table, :messages do
      resource AshEnterprise.Canonical.Message
      fields [:sent, :sender_label, :preview]
      query :messages
      context_filter conversation_id: :thread
      require_context [:thread]
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

    field :people do
      label "People"
      links :people
      link_label :label
    end

    field :sent do
      label "Sent"
    end

    field :sender_label do
      label "From"
      link :sender
    end

    field :preview do
      label "Message"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.SlackUI do
  @moduledoc """
  Slack — Slack conversations from the canonical model, newest activity
  first, each labelled by kind (channel, private channel, group DM, DM — from
  the conversation's `kind` once the projection records it). A conversation
  opens in detail with its people and its messages as a related table, each
  sender a link to People. Search reaches senders by
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

    query :messages do
      sortable [:sent_at]
      default_sort sent_at: :asc
      page_size 50
      max_page_size 200
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
      fields [:subject, :kind_label, :last_activity, :message_count, :people]
    end

    # The conversation's messages, oldest first, each sender a link to People.
    component :table, :messages do
      resource AshEnterprise.Canonical.Message
      fields [:sent, :sender_label, :preview]
      query :messages
      context_filter conversation_id: :conversation
      require_context [:conversation]
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

    field :people do
      label "People"
      links :people
      link_label :label
    end

    field :sent do
      label "Sent"
    end

    field :sender_label do
      label "From"
      link :sender
    end

    field :preview do
      label "Message"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.ApprovalsUI do
  @moduledoc """
  Approvals — the human tasks waiting on the actor (or one of their teams),
  oldest first, with what each is about. Approve / Reject decide the task
  through the process engine (`HumanTask.approve` / `.reject`, which check
  candidacy first); Reject asks for an optional comment. An open task is any
  candidate's to decide; a claimed one only its holder's, and anyone else's
  click is refused as Forbidden.

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

      fields [
        :subject_label,
        :name,
        :status,
        :waiting_since,
        :assignee_label,
        :run_stage,
        :subject_detail
      ]
    end

    # No `visible_when` on Approve / Reject: the handler would then re-read
    # the row through `:awaiting_me` first, and a person who names a task by
    # id that is not theirs would get a bare "request failed" instead of the
    # action's Forbidden (AcpLowPrivilegeTest). A claimed task is its
    # holder's alone to decide; `DecideTask` refuses everyone else.
    action :reject do
      prompt_fields [:comment]
      prompt_title "Reject — add a note for the record (optional)"
    end

    # The subject is polymorphic: a typed reference (`<surface>:<id>`) the
    # `record` link target resolves when it is opened.
    field :subject_label do
      label "About"
      link {:record, :subject_ref}
    end

    field :assignee_label do
      label "Claimed by"
      link {:users, :assignee_id}
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

    # The task's process run, on its flight view (the task's reader may read
    # the run: `AshEnterprise.Security.Checks.TaskInstance`).
    field :run_stage do
      label "Where it stands"
      source [:instance, :stage_label]
      link :instance
    end
  end
end
