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
  With the in-zone generative profile configured and no `AI_INTERPRETER_MODEL`,
  interpretation runs in the zone and needs no key (`AshEnterprise.AI.Models`).
  """

  require Logger

  alias AshEnterprise.AI.Models
  alias AshEnterprise.AI.Proposal
  alias AshEnterprise.AI.RequestClassifier
  alias AshEnterprise.Surfaces

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
          | {:assistant, String.t()}

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

  defp to_plan(%{kind: :show_surface} = intent, _request, actor, _tenant) do
    case Surfaces.fetch_helper(intent.surface, actor) do
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
    design(request, &compose/2)
  end

  # The requester's own calendar, mail or tasks: not this console's to read.
  # The assistant reads them as the person, so the request goes there.
  defp to_plan(%{kind: :ask_assistant}, request, _actor, _tenant) do
    {:ok, {:assistant, request}}
  end

  defp to_plan(%{kind: kind}, _request, _actor, _tenant) do
    {:error,
     "I understood that as #{inspect(kind)}, which this console does not support. " <>
       "It can assign a role to a user, show one of the declared surfaces " <>
       "(#{Enum.join(Surfaces.names(), ", ")}), or compose a table for you."}
  end

  @max_repairs 1

  @refused "I could not build a table for that. This helper makes tables of users, teams, " <>
             "business units, roles and legacy users: try naming one of those and the " <>
             "columns you want. For your own calendar, mail or tasks, ask the assistant " <>
             "at /app/agent."

  @malformed_feedback "- Your previous answer was not one complete JSON object. Return the " <>
                        "whole spec as valid JSON text, and keep it short."

  @doc """
  Composes a table for `request` and resolves it against the allowlist.

  `compose` is the model call, `fn request, feedback -> {:ok, spec} |
  {:error, :malformed} | {:error, message} end` (`RequestClassifier.compose_surface/2`
  in the application; a test passes a script). Public, like `plan/4`, because it is
  the seam below the model.

  A spec the server refuses, or one that is not a complete JSON object, goes
  back to the model (#{@max_repairs} repair) with the reasons as `feedback`,
  before anything is shown. Those
  reasons name DSL entities and are written for whoever writes a spec, so the
  person never reads them: a spec still refused after the repair ends in a
  plain sentence, and the log records only how many reasons there were,
  never the spec's names, which the model took from the request.
  """
  @spec design(
          String.t(),
          (String.t(), String.t() | nil ->
             {:ok, map()} | {:error, :malformed} | {:error, String.t()})
        ) :: {:ok, plan()} | {:error, String.t()}
  def design(request, compose), do: attempt(request, compose, nil, @max_repairs)

  # Composition is a second model call, not a bigger first one. The classifier's
  # job is to notice that nothing declared fits, which is a small judgement over
  # a short list; composing a spec needs the whole schema of every allowlisted
  # resource in its prompt. Putting both in one call would pay for the second
  # prompt on every request, including the ones answered by a declared surface.
  defp attempt(request, compose, feedback, repairs_left) do
    with {:ok, spec} <- compose.(request, feedback),
         {:ok, surface} <-
           spec
           |> declare_queries()
           |> AshA2ui.Dynamic.resolve(allowlist: Surfaces.dynamic_allowlist()) do
      {:ok, {:designed, surface, surface.title || "Composed table"}}
    else
      # `AshA2ui.Dynamic.resolve/2` fails with a LIST of `%Error{}`; `compose`
      # fails with `:malformed` or a message it has already written. Those are
      # the whole failure space, so there is no catch-all.
      {:error, errors} when is_list(errors) and repairs_left > 0 ->
        attempt(request, compose, feedback(errors), repairs_left - 1)

      # Cut off or not an object: the same one repair, then a plain sentence.
      {:error, :malformed} when repairs_left > 0 ->
        attempt(request, compose, @malformed_feedback, repairs_left - 1)

      {:error, :malformed} ->
        {:error, "The model's table spec came back incomplete. Try asking again."}

      {:error, errors} when is_list(errors) ->
        Logger.info(
          "helper: a composed spec was still refused after #{@max_repairs} repair(s) " <>
            "(#{length(errors)} error(s))"
        )

        {:error, @refused}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  # The verifiers' own messages, one per line: what the model must fix.
  defp feedback(errors),
    do: Enum.map_join(AshA2ui.Dynamic.Error.messages(errors), "\n", &"- #{&1}")

  # A component naming a query the spec never declares is the commonest slip
  # a model makes ("references undeclared query :monday_events"), and its fix
  # takes no judgement: declare it, with the DSL's defaults. A query is an
  # allowlist of what the client may ask for, so a bare one allows nothing
  # beyond the component's own read.
  defp declare_queries(%{"components" => components} = spec) when is_list(components) do
    queries = spec |> Map.get("queries") |> List.wrap()
    declared = queries |> Enum.map(&query_name/1) |> MapSet.new()

    missing =
      components
      |> Enum.flat_map(&referenced_query/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(declared, &1))

    if missing == [],
      do: spec,
      else: Map.put(spec, "queries", queries ++ Enum.map(missing, &%{"name" => &1}))
  end

  defp declare_queries(spec), do: spec

  defp referenced_query(%{"query" => name}) when is_binary(name), do: [name]
  defp referenced_query(_component), do: []

  defp query_name(%{"name" => name}), do: name
  defp query_name(_query), do: nil

  defp compose(request, feedback) do
    case RequestClassifier.compose_surface(request, %{feedback: feedback}) do
      {:ok, %AshEnterprise.AI.SurfaceSpec{spec: json}} when is_binary(json) ->
        decode_spec(json)

      {:ok, %{"spec" => json}} when is_binary(json) ->
        decode_spec(json)

      {:ok, _other} ->
        {:error, "The model did not return a table spec. Try asking again."}

      {:error, error} ->
        {:error, "Could not compose a table: #{Exception.message(error)}"}
    end
  rescue
    error -> {:error, "Could not compose a table: #{Exception.message(error)}"}
  end

  # The spec travels as JSON text -- see `AshEnterprise.AI.SurfaceSpec` for why
  # it cannot be a free-form `:map` return -- so the last mile is decoding it
  # back into the map the surface composer expects.
  defp decode_spec(json) do
    case Jason.decode(json) do
      {:ok, spec} when is_map(spec) -> {:ok, spec}
      {:ok, _other} -> {:error, :malformed}
      {:error, _error} -> {:error, :malformed}
    end
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
  #
  # Before any of that, the ADR 0042 flow guard: under REQUIRE_IN_ZONE_MODELS a
  # model outside the zone is refused here with the guard's own message, and
  # the in-zone profile needs no provider key at all (its host and key come
  # from the profile, `AshEnterprise.AI.Models`).
  defp key_status do
    model = AshEnterprise.AI.model()
    target = Models.resolve(model)

    case Models.check(target, "ai.interpret_request") do
      {:error, refusal} -> {:error, Exception.message(refusal)}
      :ok when target.residency == :in_zone -> :ok
      :ok -> hosted_key_status(model)
    end
  end

  defp hosted_key_status(model) do
    # The `String.trim/1` step is the load-bearing one. An empty key is *found* by
    # `ReqLLM.Keys.get/1` and reported as configured, so without it the request
    # goes out and fails with "ANTHROPIC_API_KEY was found but is empty" -- a
    # provider error where the honest answer is that nothing is configured.
    #
    # That is the state a fresh checkout is in, not an exotic one: `.env.example`
    # ships `ANTHROPIC_API_KEY=` with nothing after it, so `cp .env.example .env`
    # sets the variable and leaves it blank. Whitespace counts too -- a key pasted
    # with a trailing newline is blank for every purpose except `byte_size/1`.
    with {:ok, %{provider: provider}} <- ReqLLM.model(model),
         {:ok, key, _source} <- ReqLLM.Keys.get(provider),
         true <- String.trim(key) != "" do
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
