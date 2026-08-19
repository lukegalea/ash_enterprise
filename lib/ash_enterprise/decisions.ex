defmodule AshEnterprise.Decisions do
  @moduledoc """
  Business rules as DMN decisions: versioned, tenant-scoped, and evidenced.

  A rule that decides whether a request is high risk, which approval chain applies, or what a
  contract is priced at is **configuration, not code**. It changes on a business timescale, it
  is authored by people who do not deploy, and when it changes an auditor wants to know which
  version decided which case. Holding it as a DMN document rather than as an `if` in an action
  is what makes all three answerable.

  Two resources, supplied by `ash_decisions` and instantiated here for the same reason the
  process tables are: they are this application's tables, so a decision inherits the ownership,
  tenancy, audit and policy set every other record has.

  ## The line this must not cross

  A decision **decides**; it does not act, and it does not authorize. `ash_bpmn`'s business
  rule task reaches this domain through `AshEnterprise.Process.DecisionResolver` and routes on
  the answer, and the mutation that follows is an ordinary Ash action with its own policies and
  validations. A rule expressed here that *enforced* something would be enforced in one place
  and bypassed by every other caller — the controller-layer authorization mistake in a new
  costume, and the thing
  [thesis 1](../../docs/manifesto/01-model-your-domain.md) exists to eliminate.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Decisions.Definition
    resource AshEnterprise.Decisions.Evaluation
  end

  @doc """
  Evaluates the decision `key` for `tenant`, and records what it decided.

  Which *version* is evaluated is resolved through `AshEnterprise.Process.Resolver`, so a
  tenant that has customized a decision runs its own and every other tenant runs the platform
  baseline — the same binding model processes use, because a decision diverges for exactly the
  same reasons and should not need a second mechanism.

  Note what this does **not** do: it resolves at call time rather than pinning. That is the
  opposite of how a process instance behaves and it is deliberate. A process version is a
  *shape*, and changing it under a running instance can leave a token with nowhere to stand. A
  decision is a *rule*, and the whole reason a business keeps rules outside code is that
  changing one takes effect without redeploying or restarting what is already in flight.

  Options: `:tenant` (required), `:decision` (when the document defines several), `:timeout`,
  `:correlation_id`, and `:record` to suppress the evidence row for a designer preview.
  """
  @spec evaluate(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def evaluate(key, inputs, opts) do
    tenant = Keyword.fetch!(opts, :tenant)

    with {:ok, definition} <- AshEnterprise.Process.Resolver.resolve(:decision, key, tenant) do
      AshDecisions.Evaluator.evaluate(
        definition,
        inputs,
        opts
        |> Keyword.take([:decision, :timeout, :correlation_id, :record])
        |> Keyword.merge(
          evaluation_resource: AshEnterprise.Decisions.Evaluation,
          scope: %AshDecisions.Scope{
            actor: AshEnterprise.Platform.SystemActor.process(),
            tenant: tenant
          }
        )
      )
    end
  end
end
