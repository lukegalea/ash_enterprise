defmodule AshEnterprise.Test.Execution.NoteReader do
  @moduledoc """
  A test agent offered a tool with no effects declaration (`ClinicNote.read`), so it
  registers as a draft that cannot be published.
  """

  use AshAgent.Agent,
    key: "clinic.note_reader",
    instructions: "Read the clinic's notes.",
    model_profile: "in_zone_generative",
    tools: [{AshEnterprise.Test.Execution.ClinicNote, :read}],
    limits: [
      max_steps: 1,
      max_tool_calls: 1,
      deadline: [minutes: 5],
      token_budget: 1_000,
      max_repairs: 0
    ]
end
