defmodule AshEnterprise.Acp.Session do
  @moduledoc false

  # One ACP session. Lives in the supervised ETS store until epic E5's durable
  # `AgentSession` resource replaces it (dogfood §6).

  defstruct [:session_id, :actor, transcript: []]
end
