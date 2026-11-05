defmodule AshEnterprise.Test.Quality.ReferralTriagerV2 do
  @moduledoc """
  The same agent as `AshEnterprise.Test.Quality.ReferralTriager`, key and tools, with new
  instructions: a candidate for a release.
  """

  use AshAgent.Agent,
    key: "clinic.referral_triager",
    instructions:
      "Read the specialist's letter, record a note of what it says and refer when the letter " <>
        "asks you to. Be brief.",
    model_profile: "in_zone_generative",
    tools: [
      {AshEnterprise.Test.Execution.ReferralLetters, :read_letter},
      {AshEnterprise.Test.Execution.ClinicNote, :record},
      {AshEnterprise.Test.Execution.ReferralBoard, :refer}
    ],
    limits: [
      max_steps: 4,
      max_tool_calls: 6,
      deadline: [minutes: 30],
      token_budget: 20_000,
      max_repairs: 1
    ],
    output_type: :map
end
