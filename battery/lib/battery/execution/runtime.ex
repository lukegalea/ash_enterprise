defmodule Battery.Execution.Runtime do
  @moduledoc """
  The battery's `AshAgent.Runtime`: every step calls `Battery.ScriptedModel` (test
  support) instead of a provider. Nothing reaches a network.
  """

  @behaviour AshAgent.Runtime

  @impl true
  def loop_options(_version, _run, caller) do
    {:ok,
     model: "openai:gpt-4o-mini", req_llm: Battery.ScriptedModel, req_llm_opts: [caller: caller]}
  end
end
