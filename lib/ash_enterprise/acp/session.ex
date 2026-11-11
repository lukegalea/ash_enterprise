defmodule AshEnterprise.Acp.Session do
  @moduledoc false

  # One ACP session, held in the supervised ETS store (`AshEnterprise.Acp.Store`).

  defstruct [:session_id, :actor, :updated_at, transcript: []]
end
