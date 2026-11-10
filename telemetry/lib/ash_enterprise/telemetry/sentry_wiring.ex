defmodule AshEnterprise.Telemetry.SentryWiring do
  @moduledoc """
  Connects Sentry (or a Sentry-compatible backend such as GlitchTip) to the traces.

  ## Host configuration

      config :sentry,
        dsn: System.get_env("SENTRY_DSN"),
        before_send: {#{inspect(__MODULE__)}, :before_send},
        # Only when Sentry's structured logs are on (`logs:`).
        before_send_log: {#{inspect(__MODULE__)}, :before_send_log},
        integrations: [
          oban: [
            capture_errors: true,
            should_report_error_callback: &#{inspect(__MODULE__)}.final_attempt?/2
          ]
        ]

      # Endpoint, after Plug.Parsers. No Sentry.PlugCapture on Bandit: the logger
      # handler catches crashes.
      plug Sentry.PlugContext, body_scrubber: {#{inspect(__MODULE__)}, :scrub_body}
      # Browser reports, when `priv/js/sentry_browser.js` is in use: before Plug.Parsers.
      plug AshEnterprise.Telemetry.SentryTunnel

      # live_session
      on_mount: [{Sentry.LiveViewHook, scrubber: {#{inspect(__MODULE__)}, :scrub_live_view_params, []}}]

  and pass `sentry: true` to `AshEnterprise.Telemetry.setup/1` to add
  `Sentry.LoggerHandler`, or set `config :sentry, logs: [...]` for Sentry's own attached
  handler (then `setup/1` adds nothing, so a crash is not reported twice). The handler's
  default excludes the `:bandit` domain because it assumes `Sentry.PlugCapture`;
  `setup/1` keeps Bandit in, since without `PlugCapture` that log line is the only
  report of a request crash.

  ## Scrubbing

  `before_send/1` runs on every event and fails closed: if it raises, the event is
  dropped rather than sent unscrubbed. Request bodies and LiveView params keep their
  shape and lose every value, query strings go, stack frames keep their location and
  lose their arguments, and a crash report keeps its reason's tag and loses the last
  message and process state.

  The logger handler `setup/1` adds (or Sentry's own, when `config :sentry, logs:`
  attached it) gets the OTLP log handler's filter, so a crash report's message and
  Sentry's structured logs are built from the scrubbed event; only `crash_reason` is
  kept, because the handler reports the exception from it. `before_send_log/1` is the
  second line for structured logs: it scrubs the body and keeps scalar attributes.

  ## Decisions

    * **Sentry's OpenTelemetry span processor and sampler stay off.** Traces belong to
      the OTLP pipeline. Turning them on would send every span a second time as Sentry
      transactions and replace the sampling decision; Sentry here is the error
      tracker only. Sentry still reads the current span to attach `contexts.trace`.
    * **Oban: one report per job, on the final attempt.** Sentry's integration otherwise
      reports every failed attempt, so a job with 20 attempts files 20 events. Span
      exceptions are recorded on every attempt, so retries remain visible in the trace.
    * SigNoz's Exceptions page is for "this trace's exception"; the error tracker is the
      triage queue. Alert on one of them.
  """

  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.LogScrub
  alias AshEnterprise.Telemetry.Sanitize
  alias AshEnterprise.Telemetry.Settings

  @filtered "[Filtered]"
  @sensitive_key ~r/pass|secret|token|auth|cookie|session|csrf|email|phone|ssn|credit|card|api[_-]?key|bearer|referr?er|forwarded|real[_-]?ip|remote[_-]?(?:addr|port)|_traceparent/i
  @crash_tail ~r/\n(?:Last message|State:|Function:|\s+Args:)/
  @tuple_reason ~r/(\*\* \(stop\) \{:?[\w.]+).*/s
  @process_data [
    :genserver_state,
    "genserver_state",
    :last_message,
    "last_message",
    :crash_reason,
    "crash_reason"
  ]
  @scrub_filter :ash_enterprise_telemetry_export_scrub
  @max_attribute_bytes 1_024

  @doc "`:before_send` callback: adds join tags and scrubs. Returns `nil`, dropping the event, on failure."
  @spec before_send(struct()) :: struct() | nil
  def before_send(%{__struct__: Sentry.Event} = event) do
    event
    |> add_tags()
    |> scrub_event()
  catch
    _kind, _reason -> nil
  end

  @doc """
  `:before_send_log` callback for Sentry's structured logs: the body is scrubbed as a
  crash message is, the template and parameters go, and attributes keep scalars only.
  Returns `nil`, dropping the log, on failure.
  """
  @spec before_send_log(struct()) :: struct() | nil
  def before_send_log(%{__struct__: Sentry.LogEvent, body: body} = log) when is_binary(body) do
    %{
      log
      | body: LogScrub.text(body),
        template: nil,
        parameters: nil,
        attributes: scalar_attributes(log.attributes)
    }
  catch
    _kind, _reason -> nil
  end

  def before_send_log(_log), do: nil

  defp scalar_attributes(attributes) when is_map(attributes) do
    for {key, value} <- attributes,
        key not in @process_data,
        value = scalar_attribute(value),
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  defp scalar_attributes(_attributes), do: %{}

  defp scalar_attribute(value) when is_binary(value),
    do: Sanitize.truncate(value, @max_attribute_bytes)

  defp scalar_attribute(value) when is_number(value) or is_boolean(value), do: value

  defp scalar_attribute(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp scalar_attribute(_value), do: nil

  @doc false
  # Adds `Sentry.LoggerHandler`, or, when Sentry attached its own for `logs:`, gives
  # that one the scrub filter. A second handler would report every crash twice.
  @spec add_logger_handler() :: :ok
  def add_logger_handler do
    {id, filter} = logger_filter()

    case :logger.get_handler_config(:sentry_log_handler) do
      {:ok, _config} ->
        case :logger.add_handler_filter(:sentry_log_handler, id, filter) do
          :ok -> :ok
          {:error, {:already_exist, _id}} -> :ok
        end

      {:error, _not_found} ->
        config = %{
          config: %{capture_metadata: [:correlation_id], capture_excluded_domains: [:cowboy]},
          filter_default: :log,
          filters: [{id, filter}]
        }

        _ = :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, config)
        :ok
    end
  end

  @doc false
  # The OTLP log handler's filter, keeping the `crash_reason` Sentry reports from.
  def logger_filter, do: {@scrub_filter, {&LogScrub.filter/2, %{keep: [:crash_reason]}}}

  @doc """
  Sentry Oban callback (`should_report_error_callback`): report only the attempt
  that exhausts the job's retries.
  """
  @spec final_attempt?(module() | nil, struct()) :: boolean()
  def final_attempt?(_worker, %{attempt: attempt, max_attempts: max_attempts}) do
    attempt >= max_attempts
  end

  @doc """
  `Sentry.LiveViewHook` scrubber: keeps a params map's shape and a top-level event name,
  and drops the values, because LiveView params are unmodified user input.
  """
  @spec scrub_live_view_params(term()) :: map()
  def scrub_live_view_params(params) when is_map(params) and not is_struct(params) do
    Map.new(params, fn
      {key, value} when key in [:event, "event"] and is_binary(value) -> {key, value}
      {key, value} -> {key, filter_values(value)}
    end)
  end

  # `:not_mounted_at_router` reaches here on a nested LiveView.
  def scrub_live_view_params(_params), do: %{}

  @doc "`Sentry.PlugContext` body scrubber."
  @spec scrub_body(Plug.Conn.t()) :: map()
  def scrub_body(%{params: params}) when is_map(params) and not is_struct(params),
    do: filter_values(params)

  def scrub_body(_conn), do: %{}

  defp add_tags(event) do
    tags =
      %{}
      |> put_tag("trace_id", trace_id(event))
      |> put_tag("span_id", span_id(event))
      |> put_tag("correlation_id", correlation())

    %{event | tags: Map.merge(tags, event.tags || %{})}
  end

  defp put_tag(tags, _key, nil), do: tags
  defp put_tag(tags, key, value), do: Map.put(tags, key, value)

  defp trace_id(event) do
    current_hex(:otel_trace_id) || get_in(trace_context(event), [:trace_id])
  end

  defp span_id(event) do
    current_hex(:otel_span_id) || get_in(trace_context(event), [:span_id])
  end

  defp current_hex(key) do
    live = OpenTelemetry.Tracer.current_span_ctx() |> OpenTelemetry.Span.hex_span_ctx()
    Map.get(live, key) || Map.get(FailedSpan.current(), key)
  end

  defp trace_context(%{contexts: %{} = contexts}) do
    case Map.get(contexts, :trace) || Map.get(contexts, "trace") do
      %{} = trace -> trace
      _other -> %{}
    end
  end

  defp trace_context(_event), do: %{}

  defp correlation do
    case Settings.correlation().current() do
      id when is_binary(id) -> id
      _other -> nil
    end
  catch
    _kind, _reason -> nil
  end

  defp scrub_event(event) do
    event
    |> Map.update!(:breadcrumbs, fn crumbs -> Enum.map(crumbs || [], &scrub_breadcrumb/1) end)
    |> Map.update!(:user, &scrub_user/1)
    |> Map.update!(:extra, &scrub_extra/1)
    |> Map.update!(:request, &scrub_request/1)
    |> Map.update!(:message, &scrub_message/1)
    |> Map.update!(:fingerprint, &scrub_fingerprint/1)
    |> Map.update!(:exception, &scrub_exceptions(&1, event.original_exception))
    |> Map.update!(:threads, &blank_all_frames/1)
  end

  defp scrub_breadcrumb(%{category: "web.live_view.info"} = crumb) do
    crumb |> Map.put(:message, @filtered) |> Map.put(:data, nil)
  end

  defp scrub_breadcrumb(%{category: "web.live_view.params"} = crumb) do
    crumb
    |> Map.update(:message, nil, &strip_query/1)
    |> Map.update(:data, nil, &scrub_crumb_data/1)
  end

  defp scrub_breadcrumb(%{category: category} = crumb)
       when category in ["web.live_view.mount", "web.live_view.event"] do
    Map.update(crumb, :data, nil, &scrub_crumb_data/1)
  end

  defp scrub_breadcrumb(crumb), do: crumb

  defp scrub_crumb_data(%{} = data), do: scrub_live_view_params(data)
  defp scrub_crumb_data(other), do: other

  defp scrub_extra(%{} = extra), do: extra |> Map.drop(@process_data) |> scrub()
  defp scrub_extra(extra), do: extra

  # A logger-reported crash formats the GenServer's last message and state into the
  # text. Only the leading description is kept.
  defp scrub_message(%{formatted: formatted} = message) do
    case crash_text(formatted) do
      ^formatted -> message
      text -> %{message | formatted: text, message: crash_text(message.message), params: nil}
    end
  end

  defp scrub_message(message), do: message

  # Then the line-by-line scrub logs get: frame arguments, an exit's call, values.
  defp crash_text(text) when is_binary(text) do
    [head | _tail] = String.split(text, @crash_tail, parts: 2)

    @tuple_reason
    |> Regex.replace(head, "\\1, ...}")
    |> LogScrub.text()
  end

  defp crash_text(text), do: text

  # Sentry fingerprints a timed-out or dead call by the call's message.
  defp scrub_fingerprint([type, "genserver_call" | _call]), do: [type, "genserver_call"]
  defp scrub_fingerprint(fingerprint), do: fingerprint

  defp scrub_exceptions(exceptions, original) when is_list(exceptions) do
    Enum.map(exceptions, fn exception ->
      exception |> blank_frames() |> scrub_value(original)
    end)
  end

  defp scrub_exceptions(exceptions, _original), do: exceptions

  defp scrub_value(exception, %{__exception__: true} = original) do
    case Sanitize.exception(original) do
      ^original -> exception
      scrubbed -> %{exception | value: Exception.message(scrubbed)}
    end
  end

  defp scrub_value(exception, _original), do: exception

  defp blank_all_frames(threads) when is_list(threads), do: Enum.map(threads, &blank_frames/1)
  defp blank_all_frames(threads), do: threads

  # Sentry fills a frame's vars from the arguments in the raw stacktrace.
  defp blank_frames(%{stacktrace: %{frames: frames} = stacktrace} = holder)
       when is_list(frames) do
    frames = Enum.map(frames, &Map.put(&1, :vars, %{}))
    %{holder | stacktrace: %{stacktrace | frames: frames}}
  end

  defp blank_frames(holder), do: holder

  defp scrub_user(%{} = user) do
    user
    |> Map.drop([:email, "email", :ip_address, "ip_address", :username, "username"])
    |> scrub()
  end

  defp scrub_user(user), do: user

  defp scrub_request(%{} = request) do
    request
    |> update_present(:query_string, fn _query -> nil end)
    |> update_present(:url, &strip_query/1)
    |> update_present(:data, &filter_values/1)
    |> update_present(:cookies, fn _cookies -> %{} end)
    |> update_present(:headers, &scrub/1)
    |> update_present(:env, &scrub/1)
  end

  defp scrub_request(request), do: request

  defp update_present(map, key, fun) do
    case map do
      %{^key => value} -> Map.put(map, key, fun.(value))
      _absent -> map
    end
  end

  defp strip_query(url) when is_binary(url) do
    url |> String.split(["?", "#"], parts: 2) |> hd()
  end

  defp strip_query(url), do: url

  # Every value goes, not just the deny-listed ones: a field's name does not say
  # whether its value is customer data.
  defp filter_values(nil), do: nil

  defp filter_values(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {key, filter_values(value)} end)
  end

  defp filter_values(_value), do: @filtered

  defp scrub(%{} = map) do
    Map.new(map, fn {key, value} ->
      cond do
        sensitive?(key) -> {key, @filtered}
        is_map(value) and not is_struct(value) -> {key, scrub(value)}
        is_list(value) -> {key, Enum.map(value, &scrub_item/1)}
        true -> {key, value}
      end
    end)
  end

  defp scrub(other), do: other

  defp scrub_item(%{} = item) when not is_struct(item), do: scrub(item)
  defp scrub_item(item), do: item

  defp sensitive?(key) when is_atom(key), do: sensitive?(Atom.to_string(key))
  defp sensitive?(key) when is_binary(key), do: Regex.match?(@sensitive_key, key)
  defp sensitive?(_key), do: false
end
