defmodule AshEnterprise.SystemOne.QuestionProposal.Transport do
  @moduledoc """
  The generative instrument transport for question proposals.

  The transport owns ONE thing: an in-zone generative call that returns the
  model's textual JSON output. Decoding is never its job — the schema is
  handed to it so structured-output runtimes can constrain generation on
  the wire (ADR 0046 point 3), and the raw text comes back for this host's
  own decode pass (`Schema.validate_document/1` + `Schema.normalise/2`), so
  an undecodable answer is retained verbatim on the refused proposal rather
  than best-effort parsed anywhere.

  ## The default transport

  `ReqLLM.generate_object/4` under the resolved profile, on the generative
  wire the host configures for it (Ollama-compatible by default, or
  OpenAI-compatible for a runtime such as the zone's Splash member): the model spec and
  the transport options (`base_url`, `api_key`, `receive_timeout`) come from
  `AshJudgments.Profile` — the same profile machinery, residency guard and
  region rule every instrument call uses. The profile must name an in-zone
  GENERATIVE runtime (ADR 0046, as amended: generative instruments are
  in-zone runtimes only; the decision runtimes serve `/v1/systemone` and
  have no generative endpoint).

  ## Tests

  Tests inject a fake transport returning fixed outputs (the same pattern
  as the registry judge's `:req_llm` override): no model runs, and the
  decode pipeline — success and every refusal path — is exercised against
  the real schema.
  """

  @callback generate(
              spec :: term(),
              req_llm_opts :: keyword(),
              schema :: map(),
              prompt :: String.t()
            ) :: {:ok, raw_json :: binary()} | {:error, term()}

  @doc "The resolved profile + transport options for one instrument call."
  @callback resolve(profile :: atom()) ::
              {:ok, spec :: term(), req_llm_opts :: keyword()} | {:error, term()}

  # The default transport: AshJudgments.Profile resolution + ReqLLM
  # structured output.
  defmodule ReqLLM do
    @moduledoc false
    @behaviour AshEnterprise.SystemOne.QuestionProposal.Transport

    # This module's own name shadows the dependency; the absolute alias
    # reaches the real ReqLLM.
    alias Elixir.ReqLLM, as: ReqLLMDep

    alias AshEnterprise.AI.Models
    alias AshJudgments.Profile

    @impl true
    # @dialyzer nowarn_function — genuine false positive: the ok path is
    # proven at runtime (the resolution tests go through this exact chain),
    # but the package's raise-heavy pin/region guards erase the success
    # branch from Dialyzer's success typing of model_spec/3. The wire
    # helpers called only from that branch (spec/3, wire_opts/2) read as
    # "never called" for the same reason; the resolution tests call them.
    @dialyzer {:nowarn_function, resolve: 1, spec: 3, wire_opts: 2}
    def resolve(profile) do
      # The profile machinery runs the guards that matter — residency
      # (ADR 0042), the region rule, pin — then the transport translates
      # to the GENERATIVE wire: the profile registry's wire vocabulary is
      # the decision wire (`:typesafe`, /v1/systemone), and which
      # generative wire a profile speaks is host configuration
      # (`:generative_wires`, see `wire/1`).
      with {:ok, _decision_spec} <-
             Profile.model_spec(%{profile: profile, family: :policy_proposals}),
           {:ok, req_llm_opts} <- Profile.req_llm_opts(profile),
           {:ok, %Profile{} = resolved} <- Profile.fetch(profile) do
        wire = wire(profile)
        spec = spec(wire[:wire], resolved, req_llm_opts)
        target = Models.instrument_target(profile, spec, resolved.residency)
        {:ok, spec, [{:model_target, target} | wire_opts(wire, req_llm_opts)]}
      end
    end

    @doc """
    The generative wire `profile` speaks, from this transport's
    `:generative_wires` config (`config/runtime.exs`). A profile not listed
    speaks the Ollama-compatible wire.
    """
    @spec wire(atom()) :: keyword()
    def wire(profile) do
      :ash_enterprise
      |> Application.get_env(AshEnterprise.SystemOne.QuestionProposal.Transport, [])
      |> Keyword.get(:generative_wires, %{})
      |> Map.get(profile, wire: :ollama)
    end

    # The Ollama-compatible wire, which req_llm reaches with an `ollama:`
    # spec and the profile's own transport opts.
    defp spec(:ollama, resolved, _req_llm_opts), do: "ollama:" <> resolved.model

    # An OpenAI-compatible runtime serves a model in no catalog, so the
    # spec is built inline against the profile's own endpoint (the
    # `AshEnterprise.AI.Models` in-zone pattern).
    defp spec(:openai, resolved, req_llm_opts) do
      ReqLLMDep.model!(%{
        provider: :openai,
        id: resolved.model,
        base_url: Keyword.fetch!(req_llm_opts, :base_url)
      })
    end

    defp wire_opts(wire, req_llm_opts) do
      case wire[:wire] do
        :ollama ->
          req_llm_opts

        :openai ->
          req_llm_opts
          # A runtime that wants no key still needs one sent, or ReqLLM
          # falls back to OPENAI_API_KEY — a hosted vendor's key, handed to
          # the in-zone host.
          |> Keyword.update(
            :api_key,
            "in-zone-no-key",
            &if(&1 in [nil, ""], do: "in-zone-no-key", else: &1)
          )
          |> Keyword.merge(Keyword.take(wire, [:reasoning_effort, :max_tokens]))
          |> Keyword.put(:wire_schema_drop, Keyword.get(wire, :wire_schema_drop, []))
          # The decode schema rides the wire as a json_schema response
          # format, as written. ReqLLM reads the mode from the TOP-LEVEL
          # options (under provider_options it is ignored, and an unknown
          # model falls back to a strict tool call); strict mode, which it
          # reads from provider_options, would rewrite the schema to
          # require every property, so a noul would be forced to carry
          # options. The host validates the decoded answer against the
          # original either way.
          |> Keyword.put(:openai_structured_output_mode, :json_schema)
          |> Keyword.put(:provider_options, openai_json_schema_strict: false)
      end
    end

    # Every generative call is recorded in the ADR 0042 call record
    # (`AshEnterprise.AI.Models`), under the target `resolve/1` attached; a
    # spec that arrives without one is classified the ordinary way, so it
    # meets the in-zone guard too.
    @impl true
    def generate(spec, req_llm_opts, schema, prompt) do
      {target, req_llm_opts} =
        Keyword.pop_lazy(req_llm_opts, :model_target, fn -> Models.resolve(spec) end)

      {drop, req_llm_opts} = Keyword.pop(req_llm_opts, :wire_schema_drop, [])
      schema = wire_schema(schema, drop)

      with {:ok, response} <-
             Models.call(target, "system_one.proposal", :generate_object, req_llm_opts, fn opts ->
               ReqLLMDep.generate_object(spec, prompt, schema, opts)
             end),
           %{} = object <- ReqLLMDep.Response.object(response) do
        {:ok, Jason.encode!(object)}
      end
    end

    @doc """
    The schema as sent on the wire: the decode schema without the keywords
    a runtime is configured to drop (`:wire_schema_drop`). A runtime that
    checks a keyword only AFTER generating (Splash, for `pattern` and `allOf`) answers
    a violation with an error and no output, which would lose the raw
    answer a refusal must keep. The host's decode still validates against
    the full schema, so nothing dropped here is ever accepted unchecked.
    """
    @spec wire_schema(map(), [String.t()]) :: map()
    def wire_schema(schema, []), do: schema

    def wire_schema(schema, drop) when is_map(schema) do
      schema
      |> Map.drop(drop)
      |> Map.new(fn {key, value} -> {key, wire_schema(value, drop)} end)
    end

    def wire_schema(list, drop) when is_list(list), do: Enum.map(list, &wire_schema(&1, drop))
    def wire_schema(value, _drop), do: value
  end
end
