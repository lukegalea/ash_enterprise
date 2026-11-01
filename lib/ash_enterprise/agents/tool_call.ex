defmodule AshEnterprise.Agents.ToolCall do
  @moduledoc """
  A coding agent's tool call, asked of the person its run belongs to (dogfood §6, ADR
  0055 "the coding-agent bridge").

  `AshEnterprise.Agents.OmpSession` turns each bridge-dialect `tool_request` frame into
  an `AshEnterprise.Execution.Invocation` of `run_tool`, as the run's owner, keyed
  `omp:<run id>:<request id>`, so a frame the process sends twice is one request. The
  declaration asks for `:confirm`, so the invocation waits in `awaiting_approval` on its
  standalone approval task, which the owner decides: on the approvals list, or through
  `AshEnterprise.Execution.Actions.ConfirmInvocation`. Nothing else can approve it, and
  an agent cannot: deciding a task is a person's act.

  `run_tool` does nothing itself: approved, it hands the call to the agent process
  (`AshAgent.Invocation.Dispatch`, `effect_system` `"omp"`), and the invocation becomes
  `dispatched`. The session hears that (the invocation's PubSub topic) and writes
  `tool_response` approved; it hears a rejection the same way and writes it refused.
  The process's `tool_result` completes the invocation (`complete_external`), and a
  call it never answers is failed by the `:reconcile` sweep at the deadline.

  The call's input is the invocation's sealed `args`; its result, the invocation's
  `result`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:run_tool],
    extra_extensions: [AshAgent.Effects]

  @effect_system "omp"
  @answer_within [days: 1]

  resource do
    require_primary_key? false
  end

  # What the tool does is the agent's, in its workspace: anything, as far as this
  # application can tell. So a person confirms each call.
  effects do
    action :run_tool,
      kind: :execute,
      destructive?: true,
      idempotent?: false,
      open_world?: true,
      approval: :confirm,
      intent: :execute
  end

  actions do
    action :run_tool, :struct do
      description "Let a coding agent's run use one tool, once, as it asked."

      constraints instance_of: AshAgent.Invocation.Dispatch

      argument :run_id, :uuid, allow_nil?: false
      argument :request_id, :string, constraints: [max_length: 256]
      argument :tool, :string, allow_nil?: false, constraints: [max_length: 256]
      argument :input, :map, allow_nil?: false, default: %{}

      run AshEnterprise.Agents.Actions.HandToolCall
    end
  end

  @doc "The `effect_system` a handed-over call is recorded under."
  @spec effect_system() :: String.t()
  def effect_system, do: @effect_system

  @doc "How long the agent process has to answer a call it was handed."
  @spec answer_within() :: keyword()
  def answer_within, do: @answer_within

  @doc "The invocation target a tool call is."
  @spec target() :: String.t()
  def target, do: AshAgent.Invocation.Target.name(__MODULE__, :run_tool)

  @doc "The invocation key of request `request_id` in run `run_id`."
  @spec key(Ash.UUID.t(), String.t()) :: String.t()
  def key(run_id, request_id), do: "omp:#{run_id}:#{request_id}"
end
