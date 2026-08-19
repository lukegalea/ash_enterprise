defmodule AshEnterprise.Process.DecisionResolver do
  @moduledoc """
  Answers a business rule task by evaluating a published DMN decision.

  The join between the two packages, and the reason they are two: `ash_bpmn` reaches a
  decision only through this behaviour, so the process engine has no dependency on
  `ash_decisions` and a host could implement it over a config file, a feature flag service, or
  nothing at all.

  ## What "latest published" means here, and what it does not

  A business rule task's `binding="latest"` resolves the decision **at the moment the node
  executes**, not when the process was published. That is the right default and it is worth
  being explicit about, because it is the opposite of how process definitions behave: an
  instance pins its process version for life, and its decisions do not.

  The asymmetry is deliberate. A process version is a *shape* — change it under a running
  instance and there may be no node where its token is standing. A decision is a *rule*, and
  the reason a business keeps its rules outside code is precisely so that changing one takes
  effect without redeploying or restarting anything already in flight. A process that must
  freeze a rule can say so with `binding="pinned"` and a version.

  ## The evaluation is evidence

  Every invocation writes an `AshEnterprise.Decisions.Evaluation` row: which decision, which
  version, what it saw, what it answered. That is the record that makes "why did this request
  get escalated" answerable six months later, and it is the thing a hand-written `case` in an
  action cannot produce at all.
  """

  @behaviour AshBpmn.DecisionResolver

  require Ash.Query
  require Logger

  alias AshEnterprise.Decisions.Definition

  @impl true
  def decide(ref, inputs, ctx) do
    # Not `ctx[:tenant]`: the engine does not reliably supply it, and a decision evaluated
    # against no tenant records evidence the tenant that caused it cannot see.
    tenant = AshEnterprise.Process.EngineContext.tenant(ctx)

    # Through the domain facade rather than looking the definition up here, so a business rule
    # task and a trigger's routing decision resolve the same way -- including honouring a
    # tenant's binding when it has customized the decision.
    case AshEnterprise.Decisions.evaluate(ref, inputs,
           tenant: tenant,
           correlation_id: correlation_id(ctx)
         ) do
      {:ok, result} ->
        {:ok,
         %{
           outputs: outputs_map(result.outputs, result.decision),
           version: result.definition_version
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def exists?(ref) do
    # Called by the compiler at publish time, so it must answer for the tenant publishing the
    # diagram. Tenancy is not available at that point, so this asks the broadest question the
    # check is meant to answer: is there a published decision anywhere by this key? A tenant
    # publishing a process against a key only another tenant has is caught at execution
    # instead, which is the weaker of the two guarantees and is stated as such.
    Definition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^ref and status == :published)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: AshEnterprise.Platform.SystemActor.process(), tenant: nil)
    |> Enum.any?()
  rescue
    e ->
      Logger.warning(
        "decision resolver: exists?(#{inspect(ref)}) failed: #{Exception.message(e)}"
      )

      false
  end

  # A decision table with one output returns a bare value; with several it returns a context.
  #
  # A business rule task promotes *named* signals, so a bare value needs a name — and the right
  # one is the decision's own, which is what the DMN author sees in the modeller and what they
  # will write in the diagram's `ash:signal from=`. Calling it "result" would invent a third
  # vocabulary nobody asked for.
  defp outputs_map(outputs, _decision) when is_map(outputs), do: outputs
  defp outputs_map(outputs, decision), do: %{decision => outputs}

  defp correlation_id(ctx) do
    case Map.get(ctx, :instance) do
      %{correlation_id: id} -> id
      _ -> nil
    end
  end
end
