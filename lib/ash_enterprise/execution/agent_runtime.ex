defmodule AshEnterprise.Execution.AgentRuntime do
  @moduledoc """
  How an agent run's step reaches a model here (`AshAgent.Runtime`).

    * **The model.** A published version runs on the in-zone generative profile only
      (`AshEnterprise.Execution.Validations.Publishable`, ADR 0042). A step whose profile
      is not that one, or finds it unconfigured, makes no call: the run stays `running`
      until its lease expires and is tried again.
    * **The call.** Through `AshEnterprise.AI.Models.GuardedReqLLM`, so the flow guard
      applies and every call is an `AshEnterprise.AI.ModelCall` whose caller is
      `run:<run id>:<step seq>`; a step repeated after its worker died shows as a second
      call under the same name.
    * **The request's context.** A run records the correlation id and W3C trace context
      it was started under (`correlation_id/0`, `traceparent/0`), and every step runs
      under them again (`around_step/2`), so a run's audited writes join the request
      that started it, however many jobs later.

  `config :ash_enterprise, #{inspect(__MODULE__)}, req_llm_opts: [...]` adds options to
  every call (tests route calls to a scripted model with `downstream:`).
  """

  @behaviour AshAgent.Runtime

  alias AshEnterprise.AI.Models
  alias AshEnterprise.AI.Models.GuardedReqLLM
  alias AshEnterprise.Platform.Correlation

  @impl true
  def loop_options(version, _run, caller) do
    target = target()

    cond do
      version.model_profile != Models.in_zone_profile_name() ->
        {:error, {:not_in_zone_profile, version.model_profile}}

      target.residency != :in_zone ->
        {:error, :in_zone_profile_not_configured}

      true ->
        {:ok,
         model: target.spec,
         req_llm: GuardedReqLLM,
         req_llm_opts: Keyword.put(configured_opts(), :caller, caller)}
    end
  end

  @doc """
  The model target every step calls: the in-zone generative profile, resolved now. What a
  run's tools hand content to (`AshEnterprise.Assistant.ZoneGate`).
  """
  @spec target() :: struct()
  def target, do: Models.resolve(Models.default_spec())

  @impl true
  def around_step(run, fun) do
    with_trace(run.traceparent, fn ->
      case run.correlation_id do
        id when is_binary(id) -> Correlation.with_correlation(id, fun)
        _none -> fun.()
      end
    end)
  end

  @doc "The correlation id a run started now records."
  @spec correlation_id() :: String.t()
  def correlation_id, do: Correlation.id()

  @doc "The W3C `traceparent` of the span current now, or nil outside any trace."
  @spec traceparent() :: String.t() | nil
  def traceparent do
    Enum.find_value(:otel_propagator_text_map.inject([]), fn
      {"traceparent", value} -> value
      _other -> nil
    end)
  end

  defp with_trace(traceparent, fun) when is_binary(traceparent) do
    previous = OpenTelemetry.Ctx.get_current()
    :otel_propagator_text_map.extract([{"traceparent", traceparent}])

    try do
      fun.()
    after
      OpenTelemetry.Ctx.attach(previous)
    end
  end

  defp with_trace(_none, fun), do: fun.()

  defp configured_opts,
    do: Keyword.get(Application.get_env(:ash_enterprise, __MODULE__, []), :req_llm_opts, [])
end
