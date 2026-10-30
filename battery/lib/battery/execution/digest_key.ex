defmodule Battery.Execution.DigestKey do
  @moduledoc "The battery's `AshAgent.DigestKey`: one fixed key, for a deterministic suite."

  @behaviour AshAgent.DigestKey

  @impl true
  def digest_key(_invocation), do: {:ok, "battery-invocation-args-digest"}
end
