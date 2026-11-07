defmodule AshEnterprise.Assistant do
  @moduledoc """
  The assistant: a person's own chat with the in-zone model at `/app/agent`
  (Productivity OS dogfood E10.1 and E10.2).

  Three things live here, and nothing else:

    * **The conversation history** — `AshEnterprise.Assistant.Thread` and
      `AshEnterprise.Assistant.Turn`. Durable, owner-only, append-only, and
      sealed under the owner's assistant erasure scope (ADR 0024), because an
      answer quotes mail and Slack the person may later want forgotten.
    * **The read tools** — the `tools` below, each a computed `:read` on a row
      resource under `AshEnterprise.Assistant.Lookup` that reads the canonical
      model *as the signed-in person* (`authorize?: true`, the same policies as
      every other caller; manifesto 05). Few tools, small schemas, typed rows
      with record refs, sized for a ~27B in-zone model.
    * **The agent** — `AshEnterprise.Assistant.Agent`: each answer is a durable
      run of its published version (`AshEnterprise.Execution.Run`, ADR 0056),
      asked, followed and recorded by `AshEnterprise.Assistant.Ask`. Every step
      calls the in-zone generative profile only, through the ADR 0042 guard
      (`AshEnterprise.AI.Models.GuardedReqLLM`), every call recorded in
      `AshEnterprise.AI.ModelCall`. There is no hosted fallback.

  ## Reads, a composer, and requests — never a write in the loop

  Thirteen tools read (`AshEnterprise.Assistant.Lookup`), and a run takes each in its
  loop: ten over the person's own records, `stalled_reviews`, and `trace` and
  `explain`, which answer "what happened" and "why" from the execution record
  (`AshEnterprise.Execution.Entry`) as the person may read it, citing only what it
  returned. One composes (`AshEnterprise.Assistant.Compose`, E10.3): it asks for a
  table, calendar or board of the person's own records, which the server writes as
  an `AshA2ui.Dynamic` spec from a curated catalogue, resolves against the host
  allowlist and renders in the chat as the person
  (`AshEnterprise.Assistant.Composer`).

  The rest are the changes the assistant may ask for (E10.4), each an action of its
  own resource with an effects declaration that says `approval: :confirm`: add or
  finish an action item (`Canonical.Task`), draft a reply (`ReplyDraft`, below), sync
  a linked account (`Integration.LinkedAccount`), approve or reject a task waiting on
  the person (`Bpmn.HumanTask`), and merge, keep separate or mark unsure a duplicate
  (`Mdm.MatchCandidate`). A run never takes them in its loop: each call is a governed
  invocation (ADR 0055), requested as the person, that waits for their Confirm on the
  page (`AshEnterprise.Assistant.Requests`) and then runs as them. Their tool names
  are declared beside them, on their resource, or here for `draft_reply`.

  ## The zone gate

  What these tools return is personal content, so each one refuses unless the
  caller is a run, whose model is the in-zone profile, and that profile is in
  the canonical store's zone (`AshEnterprise.Assistant.ZoneGate`). Anything
  else that reaches these tools (an MCP client, a hosted agent) gets a
  refusal, not content.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAi, AshAgent.Effects.Domain]

  tools do
    tool :calendar_events, AshEnterprise.Assistant.Lookup.CalendarEvent, :calendar_events do
      description """
      The person's calendar events in a time window, optionally narrowed by
      an attendee or organizer (name or email) or by text in the title or
      location. Returns events with time, title, place, organizer, attendees
      and a ref to cite.
      """

      action_parameters []
    end

    tool :find_conversations, AshEnterprise.Assistant.Lookup.Conversation, :find_conversations do
      description """
      The person's email threads and Slack conversations, newest first:
      by source, by a person taking part, by text in the subject or messages,
      by time window, or only those whose latest message is from someone
      else and still needs a reply. Returns threads with subject, last
      activity, who wrote last, a ref to cite and an id.
      """

      action_parameters []
    end

    tool :read_messages, AshEnterprise.Assistant.Lookup.Message, :read_messages do
      description """
      The messages themselves (sender, time, text), newest first: within one
      conversation (pass its ref) or across all of them by sender, text or
      time window. Use this to read what was actually said.
      """

      action_parameters []
    end

    tool :find_people, AshEnterprise.Assistant.Lookup.Person, :find_people do
      description """
      Search the person's contacts by name or email. Returns each person's
      name, email, how many conversations they share and their next event.
      For a question about a past moment ("as of last Friday", "before the
      merge"), pass as_of: each person then lists the separate records they
      were split across at that moment.
      """

      action_parameters []
    end

    tool :my_tasks, AshEnterprise.Assistant.Lookup.Task, :my_tasks do
      description """
      The person's own tasks and action items (open by default), with due
      dates, soonest first.
      """

      action_parameters []
    end

    tool :morning_briefs, AshEnterprise.Assistant.Lookup.Brief, :morning_briefs do
      description """
      The person's recent morning briefs: the day, approval status and the
      brief's text.
      """

      action_parameters []
    end

    tool :pending_approvals, AshEnterprise.Assistant.Lookup.Approval, :pending_approvals do
      description """
      Process tasks waiting on the person's decision (approvals they can act
      on), oldest first, each with its id and the decisions it takes.
      """

      action_parameters []
    end

    tool :steward_queue, AshEnterprise.Assistant.Lookup.Duplicate, :steward_queue do
      description """
      Possible duplicate records waiting for the person's verdict as a data
      steward: how many, and for each the incoming and existing record's
      name, the match score, a ref to cite and an id. Use it for "how many
      duplicates" and before asking to merge, keep separate or mark unsure.
      """

      action_parameters []
    end

    tool :count_activity, AshEnterprise.Assistant.Lookup.ActivityCount, :count_activity do
      description """
      Counts over a time window: messages, calendar events or conversations,
      grouped by person, day or source. Use it for "how many", "who do I
      talk to most", "which day was busiest".
      """

      action_parameters []
    end

    tool :compose_surface, AshEnterprise.Assistant.Compose, :compose_surface do
      description """
      Put a live table, calendar or board of the person's own records on their
      screen, inside your answer. Use it when they ask to see, show, list on a
      calendar, lay out or put on a board. It returns no rows to you: say in
      one sentence what is shown.
      """

      action_parameters []
    end

    tool :my_accounts, AshEnterprise.Assistant.Lookup.Account, :my_accounts do
      description """
      The person's own linked accounts (Gmail, Google Calendar, Slack): each
      account's id, how its sync stands and when it last synced. Use it before
      asking to sync one.
      """

      action_parameters []
    end

    tool :stalled_reviews, AshEnterprise.Assistant.Lookup.StalledReview, :stalled_reviews do
      description """
      Reviews and other tasks that have waited on people for more than two days,
      as the person may read them: how many, the oldest with a ref to cite, and
      the same list put on their screen in your answer (it is also a page of its
      own). Use it for "stalled", "overdue" or "waiting too long" reviews.
      """

      action_parameters []
    end

    tool :trace, AshEnterprise.Assistant.Lookup.WorkEntry, :trace do
      description """
      What happened in one piece of work, in order: from a ref another tool
      returned (run:, invocation:, process_instance:, human_task:) or a
      correlation id. Each entry has its status and what that means. Rows with
      role missing are records that could not be read, were cut short or were
      never recorded: say so, never that nothing happened.
      """

      action_parameters []
    end

    tool :explain, AshEnterprise.Assistant.Lookup.WorkEntry, :explain do
      description """
      Why one record stands as it does: the record (role subject), what its
      status means and waits on, and what was recorded under it. Pass a ref or
      an entry's under. Answer only from these rows; rows with role missing
      say what is not known, and you must say it too.
      """

      action_parameters []
    end

    tool :draft_reply, AshEnterprise.Assistant.ReplyDraft, :draft do
      description """
      Ask to save a reply draft to one of the person's conversations, by its id
      from find_conversations. The draft is stored for them, never sent, and
      nothing is stored until they confirm on screen.
      """
    end
  end

  resources do
    resource AshEnterprise.Assistant.Thread
    resource AshEnterprise.Assistant.Turn
    resource AshEnterprise.Assistant.Lookup.CalendarEvent
    resource AshEnterprise.Assistant.Lookup.Conversation
    resource AshEnterprise.Assistant.Lookup.Message
    resource AshEnterprise.Assistant.Lookup.Person
    resource AshEnterprise.Assistant.Lookup.Task
    resource AshEnterprise.Assistant.Lookup.Brief
    resource AshEnterprise.Assistant.Lookup.Approval
    resource AshEnterprise.Assistant.Lookup.Duplicate
    resource AshEnterprise.Assistant.Lookup.ActivityCount
    resource AshEnterprise.Assistant.Lookup.Account
    resource AshEnterprise.Assistant.Lookup.StalledReview
    resource AshEnterprise.Assistant.Lookup.WorkEntry
    resource AshEnterprise.Assistant.Compose
    resource AshEnterprise.Assistant.PinnedApp
    resource AshEnterprise.Assistant.ReplyDraft
  end
end
