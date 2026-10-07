defmodule AshEnterprise.Agents.ToolGate do
  @moduledoc """
  The person gate on tool invocations (dogfood §6, ADR 0015).

  An approval is a resource row, exactly bound: `approve_invocation/2` and
  `reject_invocation/2` transition that one pending
  `AshEnterprise.Agents.ToolInvocation` — and only that one; the action's own
  validation rejects anything not `:pending` — and then order the bridge to
  write the matching `tool_response` to the port, which is what resumes the
  run. A foreign run, an already-decided invocation or a dead session can
  therefore never approve anything: the decision lives on the row, the wire
  message is just its delivery.

  These are person acts and deliberately *not* ash_ai tools: an agent must
  never be able to approve its own tool invocations.

  Scope: this gate governs the **bridge-dialect** `tool_request` frames of the
  OMP rpc port (spoken by the fake executable in tests and available to any
  future adapter). OMP's `--mode rpc` itself has no tool-approval frame — its
  permission gate (bash/edit/delete/move, allow_once/allow_always/reject_*)
  activates only when an **ACP client** is connected, which is exactly where
  epic E3's `AshEnterprise.Acp.Approvals` already maps permission requests
  (ADR 0015). An OMP session's live tool approvals therefore ride `omp acp`,
  not this port.
  """

  alias AshEnterprise.Agents.OmpSession
  alias AshEnterprise.Agents.ToolInvocation

  @type opts :: Keyword.t()

  @doc """
  Approves exactly this invocation: `:pending` → `:approved`, the run resumes
  with `{"type":"tool_response","id":...,"approved":true}`.

  Options pass through to the Ash action (`:actor`, `:authorize?`, `:tenant`).
  """
  @spec approve_invocation(ToolInvocation.t(), opts) ::
          {:ok, ToolInvocation.t()} | {:error, term()}
  def approve_invocation(%ToolInvocation{} = invocation, opts \\ []) do
    resolve(invocation, :approve, true, opts)
  end

  @doc """
  Rejects exactly this invocation: `:pending` → `:rejected`, the run resumes
  with `{"type":"tool_response","id":...,"approved":false}` and the tool never
  executes.
  """
  @spec reject_invocation(ToolInvocation.t(), opts) ::
          {:ok, ToolInvocation.t()} | {:error, term()}
  def reject_invocation(%ToolInvocation{} = invocation, opts \\ []) do
    resolve(invocation, :reject, false, opts)
  end

  defp resolve(invocation, action, approved?, opts) do
    # Scope the decision to the invocation's own tenant by default: the event
    # log's advisory lock needs a tenant, and a decision on this row must
    # never leak across one.
    opts = Keyword.put_new(opts, :tenant, invocation.organization_id)

    with {:ok, invocation} <- apply(ToolInvocation, action, [invocation, opts]) do
      :ok = OmpSession.tool_response(invocation.run_id, invocation.request_id, approved?)
      {:ok, invocation}
    end
  end
end
