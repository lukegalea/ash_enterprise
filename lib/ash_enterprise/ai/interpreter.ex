defmodule AshEnterprise.AI.Interpreter do
  @moduledoc """
  Turns a natural-language request into a *plan* — something the console can
  carry out, or show, or refuse.

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

  `interpret/3` returns a clear error naming the environment variable the
  *configured* model needs. It does not fall back to pattern matching: a
  fallback that silently half-works is worse than an honest failure, because it
  produces a demo that appears to prove something it does not.

  The provider follows `AshEnterprise.AI.model/0`, which `AI_INTERPRETER_MODEL`
  sets — so switching provider is a deployment concern and never a code change.
  """

  alias AshEnterprise.AI.Proposal
  alias AshEnterprise.AI.RequestClassifier
  alias AshEnterpriseWeb.A2ui.Surfaces

  @typedoc """
  What the console should do about a request.

  A tagged tuple rather than a single struct, because the three outcomes are not
  variations on one thing: a proposal is inert until a human approves it, and
  the two surfaces are shown immediately because a read is already filtered by
  the viewer's policies. Collapsing them would mean either confirming reads or
  performing writes unasked.
  """
  @type plan ::
          {:proposal, Proposal.t()}
          | {:surface, map()}
          | {:designed, struct(), String.t()}

  @doc """
  Interprets `request` and returns `{:ok, plan}` or `{:error, message}`.
  """
  @spec interpret(String.t(), term(), term()) :: {:ok, plan()} | {:error, String.t()}
  def interpret(request, actor, tenant) do
    with {:ok, intent} <- infer_intent(request) do
      to_plan(intent, request, actor, tenant)
    end
  end

  @doc """
  Turns an already-inferred intent into a plan.

  Public because it is the seam the tests need. The model call is the one part of
  this flow that cannot run without a provider; everything after it is ordinary
  code, and the moduledoc's claim that the flow is exercised without an API key
  depends on that half being reachable. Applications should call `interpret/3`.
  """
  @spec plan(AshEnterprise.AI.Intent.t(), String.t(), term(), term()) ::
          {:ok, plan()} | {:error, String.t()}
  def plan(intent, request, actor, tenant), do: to_plan(intent, request, actor, tenant)

  defp to_plan(%{kind: :assign_role} = intent, _request, actor, tenant) do
    with {:ok, proposal} <-
           Proposal.assign_role(actor, tenant, intent.user_email, intent.role_name) do
      {:ok, {:proposal, proposal}}
    end
  end

  defp to_plan(%{kind: :show_surface} = intent, _request, _actor, _tenant) do
    case Surfaces.fetch(intent.surface) do
      nil ->
        # The model named a surface that does not exist. Listing the real names
        # rather than apologising, because the next thing the person will do is
        # ask again and they need to know what to ask for.
        {:error,
         "I read that as a request to show #{inspect(intent.surface)}, which is not one of " <>
           "the surfaces here. Available: #{Enum.join(Surfaces.names(), ", ")}."}

      surface ->
        {:ok, {:surface, surface}}
    end
  end

  defp to_plan(%{kind: :design_surface}, request, _actor, _tenant) do
    design(request)
  end

  defp to_plan(%{kind: kind}, _request, _actor, _tenant) do
    {:error,
     "I understood that as #{inspect(kind)}, which this console does not support. " <>
       "It can assign a role to a user, show one of the declared surfaces " <>
       "(#{Enum.join(Surfaces.names(), ", ")}), or compose a table for you."}
  end

  # Composition is a second model call, not a bigger first one. The classifier's
  # job is to notice that nothing declared fits, which is a small judgement over
  # a short list; composing a spec needs the whole schema of every allowlisted
  # resource in its prompt. Putting both in one call would pay for the second
  # prompt on every request, including the ones answered by a declared surface.
  defp design(request) do
    with {:ok, spec} <- compose(request),
         {:ok, surface} <-
           AshA2ui.Dynamic.resolve(spec, allowlist: Surfaces.dynamic_allowlist()) do
      {:ok, {:designed, surface, surface.title || "Composed table"}}
    else
      {:error, [%{} | _] = errors} ->
        # Structured refusals from the same verifiers the compile-time DSL runs.
        # Shown rather than swallowed: "that field does not exist" is a useful
        # thing for a person to read, and it is the evidence that the spec was
        # checked rather than rendered.
        {:error,
         "I composed a table but the server refused it:\n" <>
           Enum.map_join(AshA2ui.Dynamic.Error.messages(errors), "\n", &"  - #{&1}")}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, other} ->
        {:error, "Could not compose a table for that: #{inspect(other)}"}
    end
  end

  defp compose(request) do
    case RequestClassifier.compose_surface(request) do
      {:ok, spec} when is_map(spec) -> {:ok, spec}
      {:ok, other} -> {:error, "The model returned #{inspect(other)} rather than a table spec."}
      {:error, error} -> {:error, "Could not compose a table: #{Exception.message(error)}"}
    end
  rescue
    error -> {:error, "Could not compose a table: #{Exception.message(error)}"}
  end

  defp infer_intent(request) do
    case key_status() do
      :ok -> run_prompt(request)
      {:error, message} -> {:error, message}
    end
  end

  # Asks ReqLLM about the provider we are actually going to call, rather than
  # reimplementing its lookup or guessing the provider.
  #
  # Both halves of that were wrong before. `ReqLLM.Keys.get/1` resolves in three
  # places -- an explicit `:api_key`, `config :req_llm`, and the environment
  # variable -- and checking only the middle one reported "no provider
  # configured" for a key supplied exactly as the error message instructs, since
  # `devenv`'s `dotenv` puts `.env` into the environment rather than into
  # application config. The provider list was then hardcoded to Anthropic and
  # OpenAI even though the model is configurable, so pointing `:interpreter_model`
  # at any other provider reported the same thing with its key correctly set.
  defp key_status do
    model = AshEnterprise.AI.model()

    with {:ok, %{provider: provider}} <- ReqLLM.model(model),
         {:ok, _key, _source} <- ReqLLM.Keys.get(provider) do
      :ok
    else
      _ -> {:error, not_configured_message(model)}
    end
  end

  defp not_configured_message(model) do
    # Naming the variable the configured model actually needs, rather than a
    # fixed pair, so the instruction is never wrong for the current config.
    env_var =
      case ReqLLM.model(model) do
        {:ok, %{provider: provider}} -> ReqLLM.Keys.env_var_name(provider)
        _ -> "ANTHROPIC_API_KEY"
      end

    """
    No API key is configured for `#{model}`, so natural-language requests \
    cannot be interpreted. Set #{env_var} in .env and restart, or point \
    AI_INTERPRETER_MODEL at a provider you do have a key for.

    The rest of this flow -- authorization, confirmation, execution and \
    audit -- does not depend on a provider and is exercised by the test \
    suite without one.\
    """
  end

  defp run_prompt(request) do
    case RequestClassifier.interpret_request(request) do
      {:ok, intent} -> {:ok, intent}
      {:error, error} -> {:error, "Could not interpret that request: #{Exception.message(error)}"}
    end
  rescue
    error -> {:error, "Could not interpret that request: #{Exception.message(error)}"}
  end
end
