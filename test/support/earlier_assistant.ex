defmodule AshEnterprise.Test.EarlierAssistant do
  @moduledoc """
  The assistant as an earlier release declared it: the same key, reads only, and other
  instructions. A tenant that published this one holds a copy the current code has
  drifted from, which `mix ash_enterprise.assistant.enable` must bring forward
  (`AshEnterprise.Execution.EnableAgentTest`).
  """

  use AshAgent.Agent,
    key: "assistant",
    instructions: "SYNTHETIC: an earlier release of the assistant.",
    model_profile: "in_zone_generative",
    tools: [
      {AshEnterprise.Assistant.Lookup.CalendarEvent, :calendar_events},
      {AshEnterprise.Assistant.Lookup.Task, :my_tasks},
      {AshEnterprise.Assistant.Compose, :compose_surface}
    ],
    limits: [
      max_steps: 6,
      max_tool_calls: 12,
      deadline: [minutes: 5],
      token_budget: 200_000,
      max_repairs: 1
    ],
    output_type: :string
end
