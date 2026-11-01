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
      `AshEnterprise.AI.ModelCall`. There is no hosted fallback. Every tool is
      a read, so a run takes each in its loop: none is an invocation.

  ## Reads, a composer, and proposals — never a write

  Nine tools read (`AshEnterprise.Assistant.Lookup`). One composes
  (`AshEnterprise.Assistant.Compose`, E10.3): it asks for a table, calendar or
  board of the person's own records, which the server writes as an
  `AshA2ui.Dynamic` spec from a curated catalogue, resolves against the host
  allowlist and renders in the chat as the person
  (`AshEnterprise.Assistant.Composer`). Four propose
  (`AshEnterprise.Assistant.Propose`, E10.4): each builds an
  `AshEnterprise.AI.Proposal`, which waits for the person to confirm it on the
  page and then runs as them. A tool that performs a mutation never belongs on
  this list.

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
      activity, who wrote last and a ref to cite.
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
      on), oldest first.
      """

      action_parameters []
    end

    tool :steward_queue, AshEnterprise.Assistant.Lookup.Duplicate, :steward_queue do
      description """
      Possible duplicate records waiting for the person's verdict as a data
      steward: how many, and for each the incoming and existing record's
      name, the match score and a ref. Use it for "how many duplicates" and
      before proposing a merge.
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

    tool :propose_task, AshEnterprise.Assistant.Propose, :propose_task do
      description """
      Propose adding an action item (change: add) or marking one of the
      person's open action items done (change: done). Nothing happens until
      the person confirms on screen.
      """

      action_parameters []
    end

    tool :propose_reply, AshEnterprise.Assistant.Propose, :propose_reply do
      description """
      Propose saving a reply draft to one of the person's conversations. The
      draft is stored for them, never sent. Nothing is stored until they
      confirm on screen.
      """

      action_parameters []
    end

    tool :propose_sync, AshEnterprise.Assistant.Propose, :propose_sync do
      description """
      Propose syncing the person's linked accounts (gmail, slack, calendar or
      all) now. Nothing happens until they confirm on screen.
      """

      action_parameters []
    end

    tool :propose_decision, AshEnterprise.Assistant.Propose, :propose_decision do
      description """
      Propose a decision the person makes: approve or reject a task waiting
      on them (on: task, from pending_approvals; a morning brief's approval
      is one), or merge, keep_separate or mark unsure a duplicate in their
      steward queue (on: duplicate). Nothing is decided until the person
      confirms on screen.
      """

      action_parameters []
    end
  end

  resources do
    resource AshEnterprise.Assistant.Thread
    resource AshEnterprise.Assistant.Turn
    resource AshEnterprise.Assistant.ProposalSettlement
    resource AshEnterprise.Assistant.Lookup.CalendarEvent
    resource AshEnterprise.Assistant.Lookup.Conversation
    resource AshEnterprise.Assistant.Lookup.Message
    resource AshEnterprise.Assistant.Lookup.Person
    resource AshEnterprise.Assistant.Lookup.Task
    resource AshEnterprise.Assistant.Lookup.Brief
    resource AshEnterprise.Assistant.Lookup.Approval
    resource AshEnterprise.Assistant.Lookup.Duplicate
    resource AshEnterprise.Assistant.Lookup.ActivityCount
    resource AshEnterprise.Assistant.Compose
    resource AshEnterprise.Assistant.Propose
    resource AshEnterprise.Assistant.PinnedApp
    resource AshEnterprise.Assistant.ReplyDraft
  end

  @doc "The tools the assistant agent offers the model, in the order above: `{resource, action}`."
  @spec tools() :: [{module(), atom()}]
  def tools do
    __MODULE__
    |> AshAi.Info.tools()
    |> Enum.map(&{&1.resource, &1.action})
  end

  @doc "The tool names the model sees, in the order above."
  @spec tool_names() :: [atom()]
  def tool_names do
    __MODULE__
    |> AshAi.Info.tools()
    |> Enum.map(& &1.name)
  end
end
