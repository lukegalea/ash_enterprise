defmodule AshEnterprise.Telemetry.AshTracer do
  @moduledoc """
  `OpentelemetryAsh`, with errors classified. Set `config :ash, :tracer, [#{inspect(__MODULE__)}]`.

  `OpentelemetryAsh` marks every failure as a span error, so an ordinary validation
  failure inflates the error rate, and it never records an `exception` event, so a
  real fault never appears on SigNoz's Exceptions page (which reads only span
  events named `exception`).

  This tracer splits the two:

    * **An invalid input or a forbidden action** is the system working. The status
      stays unset and the span carries `ash.error.class`.
    * **Anything else** (an unknown or framework error) sets the error status and
      records an `exception` event.

  This is a tracer rather than a span processor because a processor can change a
  span only at start: at the end, the SDK hands it the finished span by value. Here
  the error is still a struct, so its class does not have to be guessed from a
  message.

  Everything else delegates to `OpentelemetryAsh`; this is not a fork of it.
  """

  use Ash.Tracer

  alias AshEnterprise.Telemetry.Attributes

  @ordinary_classes [:invalid, :forbidden]

  @impl Ash.Tracer
  defdelegate start_span(type, name), to: OpentelemetryAsh

  @impl Ash.Tracer
  defdelegate stop_span(), to: OpentelemetryAsh

  @impl Ash.Tracer
  defdelegate trace_type?(type), to: OpentelemetryAsh

  @impl Ash.Tracer
  defdelegate get_span_context(), to: OpentelemetryAsh

  @impl Ash.Tracer
  defdelegate set_span_context(context), to: OpentelemetryAsh

  @impl Ash.Tracer
  defdelegate set_metadata(type, metadata), to: OpentelemetryAsh

  @impl Ash.Tracer
  def set_error(error, opts \\ []), do: classify(error, opts)

  @impl Ash.Tracer
  def set_handled_error(error, opts), do: classify(error, opts)

  defp classify(error, opts) do
    span_ctx = OpenTelemetry.Tracer.current_span_ctx()

    if span_ctx != :undefined do
      case error do
        %{class: class} when class in @ordinary_classes ->
          OpenTelemetry.Span.set_attribute(span_ctx, Attributes.error_class(), to_string(class))

        _fault ->
          record_fault(span_ctx, error, opts)
      end
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp record_fault(span_ctx, error, opts) do
    OpentelemetryAsh.set_error(error)
    OpenTelemetry.Span.record_exception(span_ctx, error, stacktrace(opts), [])
  end

  defp stacktrace(opts) do
    case opts[:stacktrace] do
      list when is_list(list) -> list
      _other -> []
    end
  end
end
