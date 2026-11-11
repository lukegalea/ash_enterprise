defmodule AshEnterprise.Telemetry.BanditSpans do
  @moduledoc false

  # Replaces OpentelemetryBandit's handler with one that:
  #
  #   * opens no span for the paths in `Settings.dropped_paths/0`, so the browser's
  #     span flush does not trace itself. The span is never created, because a
  #     processor cannot drop one without also skipping the processors after it;
  #   * remembers the failing span before the library closes it;
  #   * replaces the query string on the span with its parameter names, because a
  #     reset token or LiveView's `_csrf_token` is a value, and the library puts the
  #     raw string on every request;
  #   * records a failure without its arguments or the values its message prints;
  #   * cannot be detached by a failure.

  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.Sanitize
  alias AshEnterprise.Telemetry.Settings

  @skip {__MODULE__, :skip}
  @events [
    [:bandit, :request, :start],
    [:bandit, :request, :stop],
    [:bandit, :request, :exception]
  ]

  @doc "Swaps the handler. Must run straight after `OpentelemetryBandit.setup/1`."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    handler =
      [:bandit, :request, :start]
      |> :telemetry.list_handlers()
      |> Enum.find(&match?({OpentelemetryBandit, _id}, &1.id))

    :ok = :telemetry.detach(handler.id)

    :telemetry.attach_many(
      {__MODULE__, :span},
      @events,
      &__MODULE__.handle_event/4,
      handler.config
    )
  end

  @doc false
  def handle_event([:bandit, :request, suffix] = event, measurements, meta, config) do
    cond do
      suffix == :start and dropped?(meta) ->
        Process.put(@skip, true)

      suffix != :start and Process.delete(@skip) == true ->
        :ok

      true ->
        if suffix == :exception, do: FailedSpan.remember()

        OpentelemetryBandit.handle_request(
          event,
          measurements,
          safe_failure(meta, suffix),
          config
        )

        if suffix == :start do
          scrub_query(meta)
          scrub_path(meta)
        end
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_failure(%{exception: exception, stacktrace: stacktrace} = meta, :exception) do
    %{
      meta
      | exception: Sanitize.exception(exception),
        stacktrace: Sanitize.stacktrace(stacktrace)
    }
  end

  defp safe_failure(meta, _suffix), do: meta

  defp scrub_query(%{conn: %{query_string: query}}) when query != "" do
    OpenTelemetry.Tracer.set_attribute(:"url.query", Sanitize.query(query))
  end

  defp scrub_query(_meta), do: :ok

  # The span opens before the router has matched a route, so `url.path` starts as the
  # raw request path and a token in it would leave with the span. Redact it here; a
  # host that knows the route can replace it with the template later in the request
  # (the span is open until the stop event).
  defp scrub_path(%{conn: %{request_path: path}}) when is_binary(path) do
    OpenTelemetry.Tracer.set_attribute(:"url.path", Sanitize.truncate(Sanitize.path(path), 2_048))
  end

  defp scrub_path(_meta), do: :ok

  defp dropped?(%{conn: %{request_path: path}}), do: path in Settings.dropped_paths()
  defp dropped?(_meta), do: false
end
