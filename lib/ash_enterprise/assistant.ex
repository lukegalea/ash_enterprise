defmodule AshEnterprise.Assistant do
  @moduledoc """
  The assistant: a person's own chat with the in-zone model at `/app/agent`
  (Productivity OS dogfood E10.1 and E10.2).

  Three things live here, and nothing else:

    * **The conversation history** — `AshEnterprise.Assistant.Thread` and
      `AshEnterprise.Assistant.Turn`. Durable, owner-only, append-only, and
      sealed under the owner's assistant erasure scope (ADR 0024), because an
      answer quotes mail and Slack the person may later want forgotten.
    * **The read tools** — the `tools` below, each a generic action on
      `AshEnterprise.Assistant.Lookup` that reads the canonical model *as the
      signed-in person* (`authorize?: true`, the same policies as every other
      caller; manifesto 05). Few tools, small schemas, compact results with
      record refs, sized for a ~27B in-zone model.
    * **The loop** — `AshEnterprise.Assistant.Runner`, `AshAi.ToolLoop` over
      the in-zone generative profile only, through the ADR 0042 guard
      (`AshEnterprise.AI.Models.GuardedReqLLM`), every call recorded in
      `AshEnterprise.AI.ModelCall`. There is no hosted fallback.

  ## Reads, a composer, and proposals — never a write

  Eight tools read (`AshEnterprise.Assistant.Lookup`). One composes
  (`AshEnterprise.Assistant.Compose`, E10.3): it asks for a table, calendar or
  board of the person's own records, which the server writes as an
  `AshA2ui.Dynamic` spec from a curated catalogue, resolves against the host
  allowlist and renders in the chat as the person
  (`AshEnterprise.Assistant.Composer`). Three propose
  (`AshEnterprise.Assistant.Propose`, E10.4): each builds an
  `AshEnterprise.AI.Proposal`, which waits for the person to confirm it on the
  page and then runs as them. A tool that performs a mutation never belongs on
  this list.

  ## The zone gate

  What these tools return is personal content, so each one refuses unless the
  run carries an in-zone model target in the canonical store's zone
  (`AshEnterprise.Assistant.ZoneGate`). The runner always does; anything
  else that reaches these tools (an MCP client, a hosted agent) gets a
  refusal, not content.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAi]

  tools do
    tool :calendar_events, AshEnterprise.Assistant.Lookup, :calendar_events do
      description """
      The person's calendar events in a time window, optionally narrowed by
      an attendee or organizer (name or email) or by text in the title or
      location. Returns events with time, title, place, organizer, attendees
      and a ref to cite.
      """
    end

    tool :find_conversations, AshEnterprise.Assistant.Lookup, :find_conversations do
      description """
      The person's email threads and Slack conversations, newest first:
      by source, by a person taking part, by text in the subject or messages,
      by time window, or only those whose latest message is from someone
      else and still needs a reply. Returns threads with subject, last
      activity, who wrote last and a ref to cite.
      """
    end

    tool :read_messages, AshEnterprise.Assistant.Lookup, :read_messages do
      description """
      The messages themselves (sender, time, text), newest first: within one
      conversation (pass its ref) or across all of them by sender, text or
      time window. Use this to read what was actually said.
      """
    end

    tool :find_people, AshEnterprise.Assistant.Lookup, :find_people do
      description """
      Search the person's contacts by name or email. Returns each person's
      name, email, how many conversations they share and their next event.
      """
    end

    tool :my_tasks, AshEnterprise.Assistant.Lookup, :my_tasks do
      description """
      The person's own tasks and action items (open by default), with due
      dates, soonest first.
      """
    end

    tool :morning_briefs, AshEnterprise.Assistant.Lookup, :morning_briefs do
      description """
      The person's recent morning briefs: the day, approval status and the
      brief's text.
      """
    end

    tool :pending_approvals, AshEnterprise.Assistant.Lookup, :pending_approvals do
      description """
      Process tasks waiting on the person's decision (approvals they can act
      on), oldest first.
      """
    end

    tool :count_activity, AshEnterprise.Assistant.Lookup, :count_activity do
      description """
      Counts over a time window: messages, calendar events or conversations,
      grouped by person, day or source. Use it for "how many", "who do I
      talk to most", "which day was busiest".
      """
    end

    tool :compose_surface, AshEnterprise.Assistant.Compose, :compose_surface do
      description """
      Put a live table, calendar or board of the person's own records on their
      screen, inside your answer. Use it when they ask to see, show, list on a
      calendar, lay out or put on a board. It returns no rows to you: say in
      one sentence what is shown.
      """
    end

    tool :propose_task, AshEnterprise.Assistant.Propose, :propose_task do
      description """
      Propose adding an action item (change: add) or marking one of the
      person's open action items done (change: done). Nothing happens until
      the person confirms on screen.
      """
    end

    tool :propose_reply, AshEnterprise.Assistant.Propose, :propose_reply do
      description """
      Propose saving a reply draft to one of the person's conversations. The
      draft is stored for them, never sent. Nothing is stored until they
      confirm on screen.
      """
    end

    tool :propose_sync, AshEnterprise.Assistant.Propose, :propose_sync do
      description """
      Propose syncing the person's linked accounts (gmail, slack, calendar or
      all) now. Nothing happens until they confirm on screen.
      """
    end
  end

  resources do
    resource AshEnterprise.Assistant.Thread
    resource AshEnterprise.Assistant.Turn
    resource AshEnterprise.Assistant.Lookup
    resource AshEnterprise.Assistant.Compose
    resource AshEnterprise.Assistant.Propose
    resource AshEnterprise.Assistant.PinnedApp
    resource AshEnterprise.Assistant.ReplyDraft
  end

  @doc "The resources whose actions the runner exposes as tools."
  @spec tool_resources() :: [module()]
  def tool_resources,
    do: [
      AshEnterprise.Assistant.Lookup,
      AshEnterprise.Assistant.Compose,
      AshEnterprise.Assistant.Propose
    ]

  @doc "The tool names the runner hands the model, in the order above."
  @spec tool_names() :: [atom()]
  def tool_names do
    __MODULE__
    |> AshAi.Info.tools()
    |> Enum.map(& &1.name)
  end
end
