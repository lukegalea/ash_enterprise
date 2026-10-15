defmodule AshEnterprise.AI.Models do
  @moduledoc """
  Which model a caller gets, where that model runs, and the ADR 0042 flow guard
  every model call in this application passes through.

  ## Two kinds of target

  * **The in-zone generative profile.** An OpenAI-compatible runtime the
    operator has declared inside the deployment's zone (ADR 0042: "in-zone
    generative runtimes (llama.cpp, Ollama, vLLM)"). Configured from the
    environment, never from code:

    | Variable | Meaning |
    |---|---|
    | `S1_GEN_BASE_URL` | the runtime's OpenAI-compatible base URL (`http://host:port/v1`) |
    | `S1_GEN_MODEL` | the model id that runtime serves |
    | `S1_GEN_API_KEY` | its key, if it wants one (read per call, never stored in config) |
    | `S1_GEN_REASONING_EFFORT` | `none` (default), `minimal`, `low`, `medium`, `high` |

    Both of the first two must be set; then the profile exists and is the
    default model for every caller that does not name one explicitly.

  * **Anything else** — a `"provider:model"` catalogue spec such as
    `"anthropic:claude-haiku-4-5-20251001"` or `"openrouter:…"`. A hosted model
    is outside every declared zone, so it is classed `:outside_zone`. Nothing
    here can make a hosted model in-zone; only the operator's profile is.

  ## The flow guard

  `REQUIRE_IN_ZONE_MODELS=true` (`config :ash_enterprise, :ai,
  require_in_zone_models: true`) makes every call through `call/5` refuse a
  target that is not in-zone: it raises `AshEnterprise.AI.Models.OutsideZone`
  before any request is built, so no byte leaves. The same flag makes
  `AshEnterprise.Zones.ResidencyPolicy` refuse every `:sub_processor`
  instrument profile, whatever a tenant has opted into.

  Every call — made, failed or refused — is recorded in
  `AshEnterprise.AI.ModelCall`: caller, profile, model, residency, correlation
  id, duration and token counts. Never a prompt, an output or an error
  message, which can echo either.

  ## Callers

  * AshAi prompt actions: pass `req_llm: AshEnterprise.AI.Models.GuardedReqLLM`
    and `req_llm_opts: [caller: "…"]` (see `AshEnterprise.AI.RequestClassifier`).
    The same two options work for `AshAi.ToolLoop.run/2` and `stream/2`.
  * Code calling ReqLLM itself: `resolve/1` for the spec and options, then
    `call/5` around the request.
  """

  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor

  require Logger

  defmodule Target do
    @moduledoc """
    A resolved model: the ReqLLM spec to call, the transport options the
    profile adds, and where it runs. `label` is what the call record shows.
    """
    @enforce_keys [:profile, :spec, :label, :residency]
    defstruct [:profile, :spec, :label, :residency, :zone, req_llm_opts: []]

    @type t :: %__MODULE__{
            profile: String.t(),
            spec: term(),
            label: String.t(),
            residency: :in_zone | :outside_zone,
            zone: String.t() | nil,
            req_llm_opts: keyword()
          }
  end

  defmodule OutsideZone do
    @moduledoc """
    Raised when `REQUIRE_IN_ZONE_MODELS` is set and a call would reach a model
    outside the zone. Raised before the request is built: nothing was sent.
    """
    defexception [:label, :caller]

    @type t :: %__MODULE__{label: String.t() | nil, caller: String.t() | nil}

    @impl true
    def message(%{label: label, caller: caller}) do
      "#{caller}: refused to call #{label}: REQUIRE_IN_ZONE_MODELS is set and #{label} is " <>
        "outside the zone (ADR 0042). Configure the in-zone generative profile " <>
        "(S1_GEN_BASE_URL and S1_GEN_MODEL) and unset AI_INTERPRETER_MODEL, or name an " <>
        "in-zone model."
    end
  end

  @in_zone_profile "in_zone_generative"
  @default_hosted "anthropic:claude-haiku-4-5-20251001"
  @efforts %{
    "none" => :none,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high
  }

  @doc """
  The model spec for interpretation, as `AshEnterprise.AI.model/0` returns it:
  an explicit `:interpreter_model` wins, then the in-zone profile, then the
  hosted default.
  """
  @spec interpreter_spec() :: term()
  def interpreter_spec do
    case config()[:interpreter_model] do
      model when is_binary(model) and model != "" -> model
      _ -> default_spec()
    end
  end

  @doc "The in-zone profile's spec when one is configured, else the hosted default."
  @spec default_spec() :: term()
  def default_spec do
    case in_zone_spec() do
      nil -> @default_hosted
      spec -> spec
    end
  end

  @doc """
  The target for `spec` (default: `interpreter_spec/0`), classified and with
  the profile's transport options attached. Pure: makes no call and enforces
  nothing — `call/5` does that.
  """
  @spec resolve(term()) :: Target.t()
  def resolve(spec \\ interpreter_spec()) do
    profile = in_zone_profile()

    if profile && same_model?(spec, profile) do
      %Target{
        profile: @in_zone_profile,
        spec: in_zone_spec(),
        label: "openai:" <> profile[:model],
        residency: :in_zone,
        zone: profile[:zone],
        req_llm_opts: in_zone_opts(profile)
      }
    else
      %Target{profile: "hosted", spec: spec, label: label(spec), residency: :outside_zone}
    end
  end

  @doc """
  The target for an `ash_judgments` instrument profile the profile machinery
  has already resolved (and residency-checked): an `:in_cluster` profile runs
  in the data's own zone, anything else outside it.
  """
  @spec instrument_target(atom(), term(), atom()) :: Target.t()
  def instrument_target(profile, spec, residency) do
    %Target{
      profile: to_string(profile),
      spec: spec,
      label: label(spec),
      residency: if(residency == :in_cluster, do: :in_zone, else: :outside_zone),
      zone: if(residency == :in_cluster, do: canonical_zone())
    }
  end

  @doc "Whether the flow guard is on (`REQUIRE_IN_ZONE_MODELS`)."
  @spec require_in_zone?() :: boolean()
  def require_in_zone?, do: config()[:require_in_zone_models] == true

  @doc """
  The refusal for `target` under the current guard, or `:ok`. For callers
  that want to say why before they try (the helper console), not a
  substitute for `call/5`.
  """
  @spec check(Target.t(), String.t()) :: :ok | {:error, OutsideZone.t()}
  def check(%Target{residency: :in_zone}, _caller), do: :ok

  def check(%Target{} = target, caller) do
    if require_in_zone?(),
      do: {:error, %OutsideZone{label: target.label, caller: caller}},
      else: :ok
  end

  @doc """
  Runs `fun` (the request) under the flow guard and records it.

  `fun` receives `transport_opts/2` of `opts`. Its `{:ok, response}` /
  `{:error, reason}` result is returned unchanged. `operation` names the
  ReqLLM function for the record.

  Raises `OutsideZone` (after recording the refusal) when the guard is on and
  the target is not in-zone.
  """
  @spec call(Target.t(), String.t(), atom(), keyword(), (keyword() -> result)) :: result
        when result: term()
  def call(%Target{} = target, caller, operation, opts, fun) when is_function(fun, 1) do
    guard!(target, caller, operation)
    started = System.monotonic_time()
    result = fun.(transport_opts(target, opts))
    record_result(target, caller, operation, result, elapsed_ms(started))
    result
  end

  @doc """
  The flow guard alone: `:ok`, or the refusal recorded and raised. For a
  caller that records its own call (a stream, whose usage exists only once it
  has been read).
  """
  @spec guard!(Target.t(), String.t(), atom()) :: :ok
  def guard!(%Target{} = target, caller, operation) do
    case check(target, caller) do
      :ok ->
        :ok

      {:error, refusal} ->
        record(target, caller, operation, :refused, nil, 0, nil)
        raise refusal
    end
  end

  @doc """
  The ReqLLM options for a call to `target`: the profile's transport options
  under the caller's `opts`, except that an in-zone call's `base_url` and
  `api_key` always come from the profile -- a caller cannot redirect an
  in-zone call elsewhere.
  """
  @spec transport_opts(Target.t(), keyword()) :: keyword()
  def transport_opts(%Target{residency: :in_zone, req_llm_opts: profile_opts}, opts) do
    pinned = Keyword.take(profile_opts, [:base_url, :api_key])

    profile_opts
    |> Keyword.merge(opts)
    |> Keyword.merge(pinned)
  end

  def transport_opts(%Target{}, opts), do: opts

  @doc "Milliseconds since a `System.monotonic_time/0` reading."
  @spec elapsed_ms(integer()) :: non_neg_integer()
  def elapsed_ms(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

  @doc """
  Records one call that `call/5` did not wrap — a stream, whose usage is only
  known once it has been read. Never raises: a call record that cannot be
  written is logged (structurally) rather than failing the call it describes.
  """
  @spec record(Target.t(), String.t(), atom(), atom(), map() | nil, integer(), String.t() | nil) ::
          :ok
  def record(%Target{} = target, caller, operation, outcome, usage, duration_ms, error_class) do
    ModelCall.record!(
      %{
        caller: caller,
        profile: target.profile,
        model: target.label,
        residency: target.residency,
        zone: target.zone,
        operation: operation,
        outcome: outcome,
        correlation_id: Correlation.id(),
        input_tokens: token(usage, [:input_tokens, :prompt_tokens]),
        output_tokens: token(usage, [:output_tokens, :completion_tokens]),
        duration_ms: duration_ms,
        error_class: error_class
      },
      actor: SystemActor.system()
    )

    :ok
  rescue
    error ->
      Logger.error(
        "model call record failed: #{inspect(error.__struct__)} (caller #{caller}, #{target.label})"
      )

      :ok
  end

  @doc "The error class name of a failed result, for the record. Never its message."
  @spec error_class(term()) :: String.t()
  def error_class(%{__struct__: struct}), do: inspect(struct)
  def error_class(other) when is_atom(other), do: inspect(other)
  def error_class(_other), do: "unknown"

  # -- internals ---------------------------------------------------------------

  defp record_result(target, caller, operation, {:ok, response}, duration) do
    record(target, caller, operation, :ok, usage_of(response), duration, nil)
  end

  defp record_result(target, caller, operation, {:error, reason}, duration) do
    record(target, caller, operation, :error, nil, duration, error_class(reason))
  end

  defp record_result(target, caller, operation, _other, duration) do
    record(target, caller, operation, :ok, nil, duration, nil)
  end

  defp usage_of(%{usage: usage}) when is_map(usage), do: usage
  defp usage_of(_), do: nil

  defp token(nil, _keys), do: nil

  defp token(usage, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(usage, key) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end)
  end

  defp in_zone_opts(profile) do
    [
      base_url: profile[:base_url],
      # An OpenAI-compatible runtime that wants no key still needs ReqLLM to
      # send one rather than fall back to OPENAI_API_KEY -- which would hand a
      # hosted vendor's key to the in-zone host.
      api_key: resolve_value(profile[:api_key]) || "in-zone-no-key",
      receive_timeout: profile[:receive_timeout] || 120_000
    ]
    |> maybe_put(:reasoning_effort, Map.get(@efforts, profile[:reasoning_effort] || "none"))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_value({:system, var}) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp resolve_value(value) when is_binary(value) and value != "", do: value
  defp resolve_value(_), do: nil

  defp in_zone_profile do
    case config()[:in_zone_generative] do
      profile when is_list(profile) ->
        if present?(profile[:base_url]) and present?(profile[:model]), do: profile

      _ ->
        nil
    end
  end

  defp in_zone_spec do
    case in_zone_profile() do
      nil ->
        nil

      profile ->
        ReqLLM.model!(%{provider: :openai, id: profile[:model], base_url: profile[:base_url]})
    end
  end

  # In-zone means exactly the operator's profile: the same model at the same
  # host. A catalogue string naming the same model id is NOT in-zone -- it
  # resolves to the vendor's endpoint.
  defp same_model?(%{id: id, base_url: base_url}, profile),
    do: id == profile[:model] and base_url == profile[:base_url]

  defp same_model?(_spec, _profile), do: false

  defp label(spec) when is_binary(spec), do: spec
  defp label(%{provider: provider, id: id}), do: "#{provider}:#{id}"
  defp label({provider, id, _}) when is_binary(id), do: "#{provider}:#{id}"
  defp label({provider, kw}) when is_list(kw), do: "#{provider}:#{kw[:id] || kw[:model]}"
  defp label(_other), do: "unknown"

  defp present?(value), do: is_binary(value) and value != ""

  defp canonical_zone do
    case Application.get_env(:ash_enterprise, AshEnterprise.Canonical.Projections.ZoneAdmission) do
      opts when is_list(opts) -> opts[:zone]
      _ -> nil
    end
  end

  defp config, do: Application.get_env(:ash_enterprise, :ai, [])
end
