defmodule AshEnterprise.Agents do
  @moduledoc """
  Agent workflows (Productivity OS Dogfood epic E5; dogfood §6).

  The Ash side of the mainframe's coding-coprocessor bridge: sessions, runs,
  transcripts and tool approvals are resources, and the OMP process is
  machinery behind `AshEnterprise.Agents.OmpSession` — never the other way
  round. The division of labor dogfood §6 fixes: Ash owns identity, state,
  policy and audit; OMP owns the coding conversation.

  ## ash_ai exposure

  The tools below are what an OMP session (or any MCP client) can call as
  typed actions: list the sessions and runs it may see, and start a run.
  Execution goes through these declared actions and the same policies as any
  other caller — the no-nesting rule: OMP's model → typed Ash action →
  deterministic result, never agent → agent.

  Exposing only *reads* is deliberate: prompting an agent is the operator's
  act (the code interface behind it, or a future privileged-and-approved
  tool — never a plain tool an agent session could call, which would be
  agent-to-agent nesting); approving its privileged tools happens through
  `AshEnterprise.Agents.ToolGate`, which is not a tool — an agent must never
  be able to approve its own tool invocations.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAi]

  tools do
    tool :list_agent_sessions, AshEnterprise.Agents.AgentSession, :read do
      description "List coding-agent sessions (workspace, provider, status)."
    end

    tool :list_agent_runs, AshEnterprise.Agents.AgentRun, :read do
      description "List coding-agent runs with their status and timestamps."
    end

    # Deliberately NO start_agent_run tool: prompting an agent is the
    # operator's act (amber_console / ACP). Exposing it as a tool would let an
    # OMP session start another coding-agent run — the agent-to-agent nesting
    # dogfood §6 forbids.
  end

  resources do
    resource AshEnterprise.Agents.AgentSession
    resource AshEnterprise.Agents.AgentRun
    resource AshEnterprise.Agents.AgentMessage
    resource AshEnterprise.Agents.ToolInvocation
    resource AshEnterprise.Agents.MorningBrief
  end
end
