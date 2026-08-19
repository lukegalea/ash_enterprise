defmodule AshEnterprise.Process.ActionInvoker do
  @moduledoc """
  Runs the Ash action a service task names.

  This is the whole of what a process is allowed to *do*, and it is deliberately a thin
  translation rather than a place with any judgement in it. A node says `action="grant_role"`;
  this finds that action and calls it, as the actor the engine is carrying, through the
  ordinary action layer — so its policies, its validations and its audit entry are exactly the
  ones a human clicking a button would get.

  ## Why the allowlist exists

  A service task's action name comes out of tenant-authored BPMN XML. Without a closed list,
  drawing a box and typing an action name would be a way to invoke *any* action in the
  application — which would make the diagram editor the most powerful surface in the product
  and the process graph a place business logic could hide.

  So the actions a process may invoke are declared here, in code, reviewed like code. Adding
  one is a deliberate act by someone who can see what it does. That is the same argument
  `.mcp.json`'s explicit tool allowlist makes for the agent surface, and it is stronger here
  because the caller is a diagram rather than a person.

  ## Idempotency is the caller's problem, and it is real

  Oban redelivers. A node may execute twice, and the token claim gate makes a *double advance*
  safe without making a *double action* safe. Every action named here must tolerate being
  invoked a second time with the same subject — which in practice means it should be
  expressible as "make this true" rather than "do this again".
  """

  @behaviour AshBpmn.ActionInvoker

  require Logger

  # `"name" => {domain_function, arity_hint}`. Deliberately explicit: see the moduledoc.
  #
  # Empty at adoption, and that is the honest starting state -- the first entry arrives with
  # the first process that needs it, and arrives with a test.
  @allowed %{}

  @impl true
  def invoke(action, ctx) do
    case Map.fetch(@allowed, action) do
      {:ok, fun} ->
        run(fun, action, ctx)

      :error ->
        # An unknown action fails the node rather than being ignored. A service task that
        # silently did nothing would leave a process that looks like it worked, which is worse
        # than one that stops.
        {:error,
         {:action_not_allowed, action,
          "add it to AshEnterprise.Process.ActionInvoker's allowlist if a process should be " <>
            "able to invoke it"}}
    end
  end

  defp run(fun, action, ctx) do
    fun.(ctx)
  rescue
    e ->
      Logger.error("process action #{action} raised: #{Exception.message(e)}")
      {:error, {:action_raised, action, Exception.message(e)}}
  end
end
