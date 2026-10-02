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

  `ReqLLM.generate_object/4` under the resolved profile: the model spec and
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

    alias AshJudgments.Profile

    @impl true
    # @dialyzer nowarn_function — genuine false positive: the ok path is
    # proven at runtime (the resolution tests go through this exact chain),
    # but the package's raise-heavy pin/region guards erase the success
    # branch from Dialyzer's success typing of model_spec/3.
    @dialyzer {:nowarn_function, resolve: 1}
    def resolve(profile) do
      # The profile machinery runs the guards that matter — residency
      # (ADR 0042), the region rule, pin — then the transport translates
      # to the GENERATIVE wire: the profile registry's wire vocabulary is
      # the decision wire (`:typesafe`, /v1/systemone) and the generative
      # in-zone runtimes speak the Ollama-compatible wire (S1-21 proved
      # /api/generate on the M5 Pro host), which req_llm reaches with an
      # `ollama:` spec and the profile's own transport opts.
      with {:ok, _decision_spec} <-
             Profile.model_spec(%{profile: profile, family: :policy_proposals}),
           {:ok, req_llm_opts} <- Profile.req_llm_opts(profile),
           {:ok, %Profile{} = resolved} <- Profile.fetch(profile) do
        {:ok, "ollama:" <> resolved.model, req_llm_opts}
      end
    end

    @impl true
    def generate(spec, req_llm_opts, schema, prompt) do
      with {:ok, response} <-
             ReqLLMDep.generate_object(spec, prompt, schema, req_llm_opts),
           %{} = object <- ReqLLMDep.Response.object(response) do
        {:ok, Jason.encode!(object)}
      end
    end
  end
end
