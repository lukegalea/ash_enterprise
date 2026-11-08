defmodule AshEnterprise.Telemetry.GenAI do
  @moduledoc """
  The GenAI spans an agent run is traced with, in the OpenTelemetry GenAI semantic
  conventions at the version `AshAgent.OpenTelemetry.version/0` pins (v1.41.0; its doc
  gives the URLs). Attached at boot (`attach/0`, from `AshEnterprise.Application`).

    * **A step** (`[:ash_agent, :run, :step]`) is an `invoke_agent {agent key}` span.
      It starts under the trace context the run recorded when it was started, which
      `AshEnterprise.Execution.AgentRuntime` restores in
      `c:AshAgent.Runtime.around_step/2`, so every step of a run, however many jobs
      later, is in the trace of the request that started it. `gen_ai.agent.version` is
      the version's `content_hash`; `gen_ai.provider.name` is the provider of the model
      the step calls (`AgentRuntime.provider/1`).
    * **A model call** is req_llm's own `chat {model}` client span
      (`ReqLLM.OpenTelemetry`), a child of the step that made it.
    * **An invocation's execution** (`[:ash_agent, :invocation, :execute]`) is an
      `execute_tool {target}` span under the trace context the invocation recorded when
      it was requested (its `traceparent`): a run's tool call sits under the step that
      asked for it.

  Each span is current while its work runs, so the Ash, Ecto and model spans inside it
  are its children. Every span also carries `ash.correlation_id`, the row's correlation
  id, which the dev trace ring indexes (`mix ash_enterprise.trace --correlation`).

  ## Content stays out

  No span carries instructions, messages, tool arguments or results:
  `AshAgent.OpenTelemetry` builds none, and req_llm's bridge is attached with
  `content: :none`, its default, so a model call's payloads are never promoted onto its
  span even when the call asks for raw telemetry payloads. There is no switch to turn
  content on.

  A failed model call's error text stays out too. The bridge writes its spans through
  `AshEnterprise.Telemetry.GenAI.ContentFreeAdapter`, which gives an error status the
  error's class rather than the provider's message, keeps an exception event's type and
  drops its message, and drops the conventions' content attributes from every span.

  ## Status

  A span ends `ok` only for an outcome that finished its work
  (`AshAgent.OpenTelemetry.status/2`). Any other outcome, an error, a raise, an exit, or
  a result nobody recognises ends it as an error with `error.type`.
  """

  require Logger

  alias AshAgent.OpenTelemetry, as: Mapping
  alias AshEnterprise.Execution.AgentRuntime
  alias AshEnterprise.Telemetry.GenAI.ContentFreeAdapter

  @handler "ash_enterprise-gen-ai"
  @req_llm_handler "ash_enterprise-req-llm"

  @doc "Attaches the agent span handler and req_llm's bridge. Called once, at boot."
  @spec attach() :: :ok
  def attach do
    :ok =
      attached(
        ReqLLM.OpenTelemetry.attach(@req_llm_handler, content: :none, adapter: ContentFreeAdapter)
      )

    events =
      for prefix <- Mapping.events(),
          suffix <- [:start, :stop, :exception],
          do: prefix ++ [suffix]

    :ok = attached(:telemetry.attach_many(@handler, events, &__MODULE__.on_event/4, nil))
  end

  defp attached(:ok), do: :ok
  defp attached({:error, :already_exists}), do: :ok

  @doc false
  # A handler that raises is detached by :telemetry for the life of the VM, and every
  # later span would be lost without a word: a failure here is logged and dropped.
  def on_event(event, _measurements, meta, _config) do
    handle(event, meta)
  rescue
    error ->
      Logger.warning(fn ->
        "#{inspect(__MODULE__)}: no span for #{inspect(event)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      end)

      :ok
  end

  defp handle([:ash_agent, :run, :step, :start], %{run: run} = meta) do
    span = Mapping.step(run, meta[:agent_version], provider: AgentRuntime.provider(run.agent_key))
    start(meta, :step, span, run.correlation_id, OpenTelemetry.Ctx.get_current())
  end

  defp handle([:ash_agent, :invocation, :execute, :start], %{invocation: invocation} = meta) do
    start(
      meta,
      :tool,
      Mapping.tool(invocation),
      invocation.correlation_id,
      parent(invocation.traceparent)
    )
  end

  defp handle([:ash_agent, _what, _action, :stop], meta),
    do: finish(meta, &Mapping.status(&1, meta[:result]))

  defp handle([:ash_agent, _what, _action, :exception], meta),
    do: finish(meta, &Mapping.status(&1, meta[:reason]))

  # The trace a row was requested in, or the trace current now when it recorded none.
  # A traceparent that does not parse gives no parent: the span starts a trace of its own.
  defp parent(traceparent) when is_binary(traceparent),
    do:
      :otel_propagator_text_map.extract_to(OpenTelemetry.Ctx.new(), [{"traceparent", traceparent}])

  defp parent(_none), do: OpenTelemetry.Ctx.get_current()

  defp start(meta, kind, span, correlation_id, parent_ctx) do
    attributes =
      if is_binary(correlation_id),
        do: Map.put(span.attributes, "ash.correlation_id", correlation_id),
        else: span.attributes

    span_ctx =
      :otel_tracer.start_span(parent_ctx, tracer(), span.name, %{
        kind: span.kind,
        attributes: attributes
      })

    token = OpenTelemetry.Ctx.attach(:otel_tracer.set_current_span(parent_ctx, span_ctx))
    Process.put(key(meta), {kind, span_ctx, token})
    :ok
  end

  defp finish(meta, status) do
    case Process.delete(key(meta)) do
      {kind, span_ctx, token} ->
        case status.(kind) do
          :ok ->
            OpenTelemetry.Span.set_status(span_ctx, OpenTelemetry.status(:ok))

          {:error, %{"error.type" => type} = attributes} ->
            OpenTelemetry.Span.set_attributes(span_ctx, attributes)
            OpenTelemetry.Span.set_status(span_ctx, OpenTelemetry.status(:error, type))
        end

        OpenTelemetry.Span.end_span(span_ctx)
        OpenTelemetry.Ctx.detach(token)

      nil ->
        :ok
    end
  end

  defp key(meta), do: {__MODULE__, meta[:telemetry_span_context]}

  defp tracer do
    :opentelemetry.get_tracer(:ash_agent, vsn(), Mapping.schema_url())
  end

  defp vsn do
    case Application.spec(:ash_agent, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end
end
