defmodule AshEnterprise.AI.Interpreter do
  @moduledoc """
  Turns a natural-language request into an `AshEnterprise.AI.Proposal`.

  This is the only part of the agent flow that involves a model, and it is
  deliberately the *smallest* part. It produces a plan; it never performs
  anything. Everything safety-relevant — authorization, execution, audit —
  happens in `AshEnterprise.AI.Proposal` as ordinary Ash code, which is why the
  agent flow is testable end to end without an API key.

  ## Structured output, not tool calling

  The model is asked for a **structured value** (`AshEnterprise.AI.Intent`)
  rather than being handed tools. Two reasons:

    * A model holding a mutation tool can perform the mutation. A model
      returning a struct cannot, no matter what the prompt says or what a user
      injects into it.
    * The return type *is* the schema. Ash derives the JSON schema from the
      TypedStruct, so there is no separate schema to keep in sync — the same
      "model your domain, derive the rest" property as everywhere else.

  Name resolution deliberately happens **after** interpretation, in
  `Proposal.assign_role/4`, running as the requesting actor. If the model
  resolved names itself it would need read tools, and its view of who exists
  could differ from the requester's.

  ## Without an API key

  `interpret/3` returns a clear error. It does not fall back to pattern
  matching: a fallback that silently half-works is worse than an honest failure,
  because it produces a demo that appears to prove something it does not.
  """

  alias AshEnterprise.AI.Proposal

  @doc """
  Interprets `request` and returns `{:ok, proposal}` or `{:error, message}`.
  """
  def interpret(request, actor, tenant) do
    with {:ok, intent} <- infer_intent(request) do
      to_proposal(intent, actor, tenant)
    end
  end

  defp to_proposal(%{kind: :assign_role} = intent, actor, tenant) do
    Proposal.assign_role(actor, tenant, intent.user_email, intent.role_name)
  end

  defp to_proposal(%{kind: kind}, _actor, _tenant) do
    {:error,
     "I understood that as #{inspect(kind)}, which this console does not support yet. " <>
       "Currently supported: assigning a role to a user."}
  end

  defp infer_intent(request) do
    if configured?() do
      run_prompt(request)
    else
      {:error,
       """
       No LLM provider is configured, so natural-language requests cannot be \
       interpreted. Set ANTHROPIC_API_KEY (or OPENAI_API_KEY) in .env and \
       restart.

       The rest of this flow -- authorization, confirmation, execution and \
       audit -- does not depend on a provider and is exercised by the test \
       suite without one.\
       """}
    end
  end

  # Asks ReqLLM the same question the actual call will ask, rather than
  # reimplementing it. `ReqLLM.Keys.get/1` resolves in three places -- an explicit
  # `:api_key`, `config :req_llm`, and the environment variable -- and checking
  # only the middle one made this report "no provider configured" for a key
  # supplied exactly as the error message instructs, since `devenv`'s `dotenv`
  # puts `.env` into the environment rather than into application config.
  defp configured? do
    Enum.any?([:anthropic, :openai], &match?({:ok, _key, _source}, ReqLLM.Keys.get(&1)))
  end

  defp run_prompt(request) do
    case AshEnterprise.AI.RequestClassifier.interpret_request(request) do
      {:ok, intent} -> {:ok, intent}
      {:error, error} -> {:error, "Could not interpret that request: #{Exception.message(error)}"}
    end
  rescue
    error -> {:error, "Could not interpret that request: #{Exception.message(error)}"}
  end
end
