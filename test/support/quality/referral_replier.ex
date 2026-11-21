defmodule AshEnterprise.Test.Quality.ReferralReplier do
  @moduledoc """
  A test agent that answers a clinician in words (`output_type: :string`), so a suite run
  of it has answers the `agent_reply_style` questions read: the reply subjects of
  `AshEnterprise.Quality.AgentReply`'s `:from_run`. Every instruction and answer is
  synthetic.
  """

  use AshAgent.Agent,
    key: "clinic.referral_replier",
    instructions: "Answer the clinician's question about a referral in plain words.",
    model_profile: "in_zone_generative",
    tools: [{AshEnterprise.Test.Execution.ReferralLetters, :read_letter}],
    limits: [
      max_steps: 4,
      max_tool_calls: 6,
      deadline: [minutes: 30],
      token_budget: 20_000,
      max_repairs: 1
    ],
    output_type: :string
end
