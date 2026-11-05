defmodule AshEnterprise.Assistant.Agent do
  @moduledoc """
  The assistant as an agent declared in code (`AshAgent.Agent`, ADR 0056): each answer
  is a durable run of its published version (`AshEnterprise.Execution.Run`), asked and
  settled by `AshEnterprise.Assistant.Ask`.

    * **Instructions** — `AshEnterprise.Assistant.Prompt.instructions/0`, the same for
      every run; the time, the conversation so far and the question are the run's input.
    * **Tools** — eleven reads a run takes in its loop (ten lookups and the composer,
      `AshEnterprise.Assistant`), and nine changes it may only ask for: actions of
      their own resources whose effects say `approval: :confirm`. A call to one of those
      is a governed invocation (ADR 0055) requested as the person; the answer ends
      there, and the person's Confirm on the page runs it as them
      (`AshEnterprise.Assistant.Requests`). The run asks; it never changes anything
      itself.
    * **Model** — the in-zone generative profile, the only one a version publishes on
      (ADR 0042).
    * **Limits** — six model calls, as many tool calls as a short answer needs, five
      minutes, and one repair of an empty answer. A run that reaches a limit is not
      lifted: the answer fails and says why.

  A tenant runs the assistant once an administrator has registered it
  (`AshEnterprise.Execution.register_agent_from_code/2`), had its publish approved by
  another, and given members its start grant (`AshEnterprise.Security.AgentStartGrant`).
  `mix ash_enterprise.assistant.enable --org <org> --as <email>` does the first part and
  requests the publish (`AshEnterprise.Execution.enable_agent_from_code/2`); approving it
  and the start grants stay people's acts. An organization with one administrator may
  opt in to let them approve it themselves (`--sole-administrator-approval`,
  `AshEnterprise.Execution.Approval`).
  """

  use AshAgent.Agent,
    key: "assistant",
    instructions: AshEnterprise.Assistant.Prompt.instructions(),
    model_profile: "in_zone_generative",
    tools: [
      {AshEnterprise.Assistant.Lookup.CalendarEvent, :calendar_events},
      {AshEnterprise.Assistant.Lookup.Conversation, :find_conversations},
      {AshEnterprise.Assistant.Lookup.Message, :read_messages},
      {AshEnterprise.Assistant.Lookup.Person, :find_people},
      {AshEnterprise.Assistant.Lookup.Task, :my_tasks},
      {AshEnterprise.Assistant.Lookup.Brief, :morning_briefs},
      {AshEnterprise.Assistant.Lookup.Approval, :pending_approvals},
      {AshEnterprise.Assistant.Lookup.Duplicate, :steward_queue},
      {AshEnterprise.Assistant.Lookup.ActivityCount, :count_activity},
      {AshEnterprise.Assistant.Lookup.Account, :my_accounts},
      {AshEnterprise.Assistant.Compose, :compose_surface},
      {AshEnterprise.Canonical.Task, :capture},
      {AshEnterprise.Canonical.Task, :complete_mine},
      {AshEnterprise.Assistant.ReplyDraft, :draft},
      {AshEnterprise.Integration.LinkedAccount, :sync_now},
      {AshEnterprise.Bpmn.HumanTask, :approve},
      {AshEnterprise.Bpmn.HumanTask, :reject},
      {AshEnterprise.Mdm.MatchCandidate, :confirm},
      {AshEnterprise.Mdm.MatchCandidate, :reject},
      {AshEnterprise.Mdm.MatchCandidate, :escalate}
    ],
    limits: [
      max_steps: 6,
      max_tool_calls: 12,
      deadline: [minutes: 5],
      token_budget: 200_000,
      max_repairs: 1
    ],
    output_type: :string

  @doc "The agent's key, which runs, versions and start grants name."
  @spec key() :: String.t()
  def key, do: "assistant"
end
