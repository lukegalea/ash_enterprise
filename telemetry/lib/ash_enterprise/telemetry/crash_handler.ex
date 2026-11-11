defmodule AshEnterprise.Telemetry.CrashHandler do
  @moduledoc """
  A logger handler that turns a process crash into a `process.crash` span with an
  `exception` event.

  HTTP requests, LiveView callbacks and Oban jobs already record exceptions on their
  own spans. A GenServer or Task crash has no span, so it would otherwise be visible
  only in logs, and SigNoz's Exceptions page reads only span events.

  A crash already recorded on a span is skipped, so one failure is one exception:
  the process's `AshEnterprise.Telemetry.FailedSpan` says so. The `bandit` logger domain
  is skipped too, because a protocol error has no action behind it. A LiveView that
  crashes outside an event (a `handle_info`, say) has no span and does get one here.
  Extra domains can be ignored with `:ignore_domains` in the handler config.

  A logger handler that raises is removed by OTP, so this one never raises.
  """

  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.Sanitize

  require OpenTelemetry.Tracer

  @handler_id :ash_enterprise_telemetry_crash_spans
  @ignored_domains [:bandit, :cowboy]

  @doc "Adds the handler at `:error` level. Idempotent."
  @spec add(keyword()) :: :ok | {:error, term()}
  def add(opts \\ []) do
    config = %{level: :error, config: %{ignore_domains: Keyword.get(opts, :ignore_domains, [])}}

    case :logger.add_handler(@handler_id, __MODULE__, config) do
      :ok -> :ok
      {:error, {:already_exist, _id}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes the handler."
  @spec remove() :: :ok | {:error, term()}
  def remove, do: :logger.remove_handler(@handler_id)

  @doc false
  def adding_handler(config), do: {:ok, config}

  @doc false
  def log(%{meta: %{crash_reason: {reason, stacktrace}} = meta}, config)
      when is_list(stacktrace) do
    unless ignored?(meta, config) do
      record(reason, stacktrace)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  def log(_event, _config), do: :ok

  defp ignored?(meta, config) do
    domain = Map.get(meta, :domain, [])
    extra = get_in(config, [:config, :ignore_domains]) || []

    Enum.any?(domain, &(&1 in @ignored_domains or &1 in extra)) or FailedSpan.recent?()
  end

  defp record(reason, stacktrace) do
    exception = normalize(reason, stacktrace)

    span_ctx =
      OpenTelemetry.Tracer.start_span("process.crash", %{
        kind: :internal,
        attributes: attributes()
      })

    OpenTelemetry.Span.record_exception(span_ctx, exception, Sanitize.stacktrace(stacktrace), [])

    OpenTelemetry.Span.set_status(
      span_ctx,
      OpenTelemetry.status(:error, Exception.message(exception))
    )

    OpenTelemetry.Span.end_span(span_ctx)
  end

  defp attributes do
    case Process.get(:"$initial_call") do
      {module, function, arity} ->
        %{"process.crash.initial_call": "#{inspect(module)}.#{function}/#{arity}"}

      _none ->
        %{}
    end
  end

  defp normalize(%{__exception__: true} = exception, _stacktrace),
    do: Sanitize.exception(exception)

  defp normalize({%{__exception__: true} = exception, _nested}, _stacktrace),
    do: Sanitize.exception(exception)

  defp normalize(reason, _stacktrace) do
    %RuntimeError{message: "process crashed: #{Sanitize.reason_label(reason)}"}
  end
end
