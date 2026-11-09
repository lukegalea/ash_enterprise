defmodule AshEnterprise.Telemetry.SentryWiring do
  @moduledoc """
  Connects Sentry (or a Sentry-compatible backend such as GlitchTip) to the traces.

  ## Host configuration

      config :sentry,
        dsn: System.get_env("SENTRY_DSN"),
        before_send: {#{inspect(__MODULE__)}, :before_send},
        integrations: [
          oban: [
            capture_errors: true,
            should_report_error_callback: &#{inspect(__MODULE__)}.final_attempt?/2
          ]
        ]

      # Endpoint, after Plug.Parsers. No Sentry.PlugCapture on Bandit: the logger
      # handler catches crashes.
      plug Sentry.PlugContext, body_scrubber: {#{inspect(__MODULE__)}, :scrub_body}

      # live_session
      on_mount: [{Sentry.LiveViewHook, scrubber: {#{inspect(__MODULE__)}, :scrub_live_view_params, []}}]

  and pass `sentry: true` to `AshEnterprise.Telemetry.setup/1` to add
  `Sentry.LoggerHandler`, or set `config :sentry, logs: [...]` for Sentry's own attached
  handler (then `setup/1` adds nothing, so a crash is not reported twice). The handler's
  default excludes the `:bandit` domain because it assumes `Sentry.PlugCapture`;
  `setup/1` keeps Bandit in, since without `PlugCapture` that log line is the only
  report of a request crash.

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
  alias AshEnterprise.Telemetry.Settings

  @filtered "[Filtered]"
  @sensitive_key ~r/pass|secret|token|auth|cookie|session|csrf|email|phone|ssn|credit|card|api[_-]?key|bearer|_traceparent/i
  @live_view_breadcrumbs ~w(web.live_view.mount web.live_view.event web.live_view.params)

  @doc "`:before_send` callback: adds join tags and scrubs."
  @spec before_send(struct()) :: struct()
  def before_send(%{__struct__: Sentry.Event} = event) do
    event
    |> add_tags()
    |> scrub_event()
  rescue
    _exception -> event
  end

  @doc """
  Sentry Oban callback (`should_report_error_callback`): report only the attempt
  that exhausts the job's retries.
  """
  @spec final_attempt?(module() | nil, struct()) :: boolean()
  def final_attempt?(_worker, %{attempt: attempt, max_attempts: max_attempts}) do
    attempt >= max_attempts
  end

  @doc """
  `Sentry.LiveViewHook` scrubber: keeps a params map's shape and event names, and drops
  the values, because LiveView params are unmodified user input.
  """
  @spec scrub_live_view_params(map()) :: map()
  def scrub_live_view_params(params) when is_map(params) do
    Map.new(params, fn
      {key, value} when key in [:event, "event"] -> {key, value}
      {key, value} when is_map(value) -> {key, scrub_live_view_params(value)}
      {key, _value} -> {key, @filtered}
    end)
  end

  @doc "`Sentry.PlugContext` body scrubber."
  @spec scrub_body(Plug.Conn.t()) :: map()
  def scrub_body(%{params: params}) when is_map(params) and not is_struct(params),
    do: scrub(params)

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
    |> Map.update!(:extra, &scrub/1)
    |> Map.update!(:request, &scrub_request/1)
  end

  defp scrub_breadcrumb(%{category: category, data: data} = crumb)
       when category in @live_view_breadcrumbs and is_map(data) do
    %{crumb | data: scrub_live_view_params(data)}
  end

  defp scrub_breadcrumb(crumb), do: crumb

  defp scrub_user(%{} = user) do
    user
    |> Map.drop([:email, "email", :ip_address, "ip_address", :username, "username"])
    |> scrub()
  end

  defp scrub_user(user), do: user

  defp scrub_request(%{data: data} = request) when is_map(data) do
    %{request | data: scrub(data), env: scrub_env(request)}
  end

  defp scrub_request(request), do: request

  defp scrub_env(%{env: env}) when is_map(env), do: scrub(env)
  defp scrub_env(request), do: Map.get(request, :env)

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
