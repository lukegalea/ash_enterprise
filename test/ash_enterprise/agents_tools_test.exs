defmodule AshEnterprise.Agents.ToolsTest do
  @moduledoc """
  The no-nesting rule as a regression: ash_ai's tool surface for the Agents
  domain is reads only. `start_agent_run` must never be a tool — an agent that
  can start another coding-agent run is the agent-to-agent nesting dogfood §6
  forbids. Runs start from the operator's surfaces (amber_console / ACP).
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Agents

  test "the ash_ai tool surface is reads only — no run-starting tool" do
    tools =
      AshAi.Info.tools(Agents)
      |> Enum.map(& &1.name)

    assert :list_agent_sessions in tools
    assert :list_agent_runs in tools
    refute :start_agent_run in tools
  end
end
