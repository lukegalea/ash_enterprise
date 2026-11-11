defmodule AshEnterprise.Telemetry.SpanException do
  @moduledoc """
  Makes every error report also an `exception` event on a span, so an error in the
  error tracker is always in the trace viewer's exceptions too, under the same trace id.
  Called from `AshEnterprise.Telemetry.SentryWiring.before_send/1`, the one point every
  server-side report passes through, in the reporting process.

  In order:

    1. **Already on a span.** A library recorded the failure on its span and said so
       (`AshEnterprise.Telemetry.FailedSpan`): a request (Bandit), a LiveView callback, an
       Oban job, or a process crash (`AshEnterprise.Telemetry.CrashHandler`). Nothing is
       added; the report's tags name that span.
    2. **A span is open.** A report made from inside traced work, `Sentry.capture_exception/2`
       after a `rescue`, say. The exception is recorded on that span.
    3. **No span.** A short span is opened to carry it: `process.crash` for a crash the
       logger reported, `error.report` otherwise. When the event already names a trace
       (`contexts.trace`), the span is opened in it.

  The event gets that span's `trace_id` and `span_id` (in its tags, through
  `before_send/1`, and in `contexts.trace`). An event with no exception records its message
  as the exception message. Events below `:error` level are left alone.
  """

  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.Sanitize

  require OpenTelemetry.Tracer

  @max_message 1_024
  @max_frames 50

  @doc "Records the event's error on a span, as described above. Never raises."
  @spec ensure(struct()) :: struct()
  def ensure(%{__struct__: Sentry.Event} = event) do
    cond do
      not error_level?(event) -> event
      FailedSpan.recent?() -> event
      true -> record(event, exception_attributes(event))
    end
  catch
    _kind, _reason -> event
  end

  defp record(event, nil), do: event

  defp record(event, attributes) do
    span = OpenTelemetry.Tracer.current_span_ctx()

    span =
      if OpenTelemetry.Span.is_recording(span) do
        OpenTelemetry.Span.add_event(span, :exception, attributes)
        span
      else
        short_span(event, attributes)
      end

    FailedSpan.put(span)
    put_trace_context(event, span)
  end

  defp short_span(event, attributes) do
    name = if event.source == :logger, do: "process.crash", else: "error.report"

    span =
      OpenTelemetry.Tracer.start_span(parent(event), name, %{
        kind: :internal,
        attributes: initial_call()
      })

    OpenTelemetry.Span.add_event(span, :exception, attributes)

    OpenTelemetry.Span.set_status(
      span,
      OpenTelemetry.status(:error, attributes[:"exception.message"])
    )

    OpenTelemetry.Span.end_span(span)
    span
  end

  # An event that already names a trace (Sentry read it where the error happened) keeps
  # it: the short span joins that trace instead of starting one.
  defp parent(event) do
    with %{} = trace <- get_in(event.contexts || %{}, [:trace]),
         {:ok, trace_id} <- hex_id(trace[:trace_id], 32),
         {:ok, span_id} <- hex_id(trace[:span_id], 16) do
      remote = :otel_tracer.from_remote_span(trace_id, span_id, 1)
      OpenTelemetry.Tracer.set_current_span(OpenTelemetry.Ctx.new(), remote)
    else
      _none -> OpenTelemetry.Ctx.new()
    end
  end

  defp hex_id(value, size) when is_binary(value) and byte_size(value) == size do
    case Integer.parse(value, 16) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> :error
    end
  end

  defp hex_id(_value, _size), do: :error

  defp initial_call do
    case Process.get(:"$initial_call") do
      {module, function, arity} ->
        %{"process.crash.initial_call": "#{inspect(module)}.#{function}/#{arity}"}

      _none ->
        %{}
    end
  end

  defp put_trace_context(event, span) do
    case OpenTelemetry.Span.hex_span_ctx(span) do
      %{otel_trace_id: trace_id, otel_span_id: span_id} ->
        trace = %{trace_id: to_string(trace_id), span_id: to_string(span_id)}
        contexts = Map.update(event.contexts || %{}, :trace, trace, &Map.merge(&1, trace))
        %{event | contexts: contexts}

      _none ->
        event
    end
  end

  defp error_level?(%{level: level}) when level in [:error, :fatal, nil, "error", "fatal"],
    do: true

  defp error_level?(_event), do: false

  # The original exception when Sentry kept it, else the event's own exception or
  # message. The same scrubbing as a span's exception elsewhere: no arguments, no state.
  defp exception_attributes(%{original_exception: %{__exception__: true} = exception} = event) do
    exception = Sanitize.exception(exception)

    %{
      "exception.type": inspect(exception.__struct__),
      "exception.message": truncate(Exception.message(exception)),
      "exception.stacktrace": stacktrace(event)
    }
  end

  defp exception_attributes(%{exception: [%{} = first | _rest]} = event) do
    %{
      "exception.type": to_string(Map.get(first, :type) || "error"),
      "exception.message": truncate(to_string(Map.get(first, :value) || "")),
      "exception.stacktrace": stacktrace(event)
    }
  end

  defp exception_attributes(%{message: %{formatted: formatted}} = event)
       when is_binary(formatted) and formatted != "" do
    %{
      "exception.type": "error",
      "exception.message": truncate(first_line(formatted)),
      "exception.stacktrace": stacktrace(event)
    }
  end

  defp exception_attributes(_event), do: nil

  # Sentry keeps frames oldest first, with the function as `Module.function/arity`; the
  # trace viewer wants newest first, as Elixir prints them.
  defp stacktrace(event) do
    frames =
      case event do
        %{exception: [%{stacktrace: %{frames: frames}} | _rest]} when is_list(frames) -> frames
        %{threads: [%{stacktrace: %{frames: frames}} | _rest]} when is_list(frames) -> frames
        _none -> []
      end

    frames
    |> Enum.reverse()
    |> Enum.take(@max_frames)
    |> Enum.map_join("\n", &frame/1)
  end

  defp frame(frame) do
    location =
      case {Map.get(frame, :filename), Map.get(frame, :lineno)} do
        {nil, _line} -> ""
        {file, nil} -> " (#{file})"
        {file, line} -> " (#{file}:#{line})"
      end

    "    #{Map.get(frame, :function) || "?"}#{location}"
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp truncate(text), do: Sanitize.truncate(text, @max_message)
end
