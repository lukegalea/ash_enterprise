defmodule AshEnterprise.Telemetry.BrowserContext do
  @moduledoc """
  Correlation and browser trace context for LiveView.

  Two telemetry handlers run around `OpentelemetryPhoenix`'s, in LiveView's own
  process, so no router or `on_mount` change is needed and every `live_session` is
  covered:

    * one attached *before* it mints a correlation id per mount and event, and
      adopts the browser's trace context so the LiveView span becomes the browser
      span's child;
    * one attached *after* it detaches that context on stop and on exception,
      keyed by `telemetry_span_context`. A LiveView is a long-lived process, so
      without this every later event would inherit the previous event's trace.

  ## Trust model

  The browser is outside the trust boundary. It is allowed to contribute one thing:
  a trace parent, so that a span it opened can be the parent of a server span.

    * It **never supplies a correlation id**, an audit identity or any attribute.
      Those are minted on the server. No handler reads them from params.
    * The `traceparent` is **strictly validated** against W3C version `00`: lower-case
      hex, exact lengths, non-zero ids. Anything else is ignored and the server span
      is a new root.
    * Its **sampled flag is replaced with `01`** before the context is extracted, so a
      client cannot suppress sampling with `-00`. On its own that would let it force
      sampling instead: a sampled remote parent selects the SDK's
      `remote_parent_sampled` sampler, which defaults to `always_on` however low the
      root sampler is set. A host sampling below 100% must configure
      `AshEnterprise.Telemetry.sampler/1`, which sends these spans to the root sampler.
      A ratio sampler reads the trace id, which the client also chose, so a client
      trying to be sampled can still pick an id that is; it gains its own events
      sampled and nothing more.
    * A forged valid `traceparent` can at worst attach server spans to a trace the
      client chose. That misleads a trace view; it cannot read data, change an audit
      row or affect authorization, because a span's parent is not used for anything
      but display. This is why adoption is opt-in and off by default.

  The feature is gated by `browser_context: true` in
  `AshEnterprise.Telemetry.setup/1`. Off, a `_traceparent` param is ignored and every
  LiveView span is rooted on the server.

  Event params carry `_traceparent` when the browser client is on. Do not log whole
  params, and do not fail on the unknown key.

  ## Naming the user action

  The handler attached after `OpentelemetryPhoenix` also writes the attributes in
  `AshEnterprise.Telemetry.Attributes` onto the `handle_event` span, using the host's
  `:event_attributes` hook (see `AshEnterprise.Telemetry.A2uiEventAttributes`).
  """

  alias AshEnterprise.Telemetry.Attributes
  alias AshEnterprise.Telemetry.FailedSpan
  alias AshEnterprise.Telemetry.Sanitize
  alias AshEnterprise.Telemetry.Settings
  alias OpenTelemetry.Ctx

  @lifecycle [
    [:phoenix, :live_view, :mount],
    [:phoenix, :live_view, :handle_params],
    [:phoenix, :live_view, :handle_event],
    [:phoenix, :live_component, :handle_event]
  ]

  @traceparent ~r/\A00-(?!0{32})[0-9a-f]{32}-(?!0{16})[0-9a-f]{16}-[0-9a-f]{2}\z/

  @max_attribute_bytes 256

  @doc """
  Attaches the start handler, and the exception handler that remembers the failing
  span while it is still current. Must run before `OpentelemetryPhoenix.setup/1`.
  """
  @spec attach_before() :: :ok | {:error, :already_exists}
  def attach_before do
    :telemetry.attach_many(
      {__MODULE__, :before},
      for(event <- @lifecycle, suffix <- [:start, :exception], do: event ++ [suffix]),
      &__MODULE__.handle_before/4,
      nil
    )
  end

  @doc "Attaches the attribute and detach handlers. Must run after `OpentelemetryPhoenix.setup/1`."
  @spec attach_after() :: :ok | {:error, :already_exists}
  def attach_after do
    events =
      for event <- @lifecycle, suffix <- [:start, :stop, :exception], do: event ++ [suffix]

    :telemetry.attach_many({__MODULE__, :after}, events, &__MODULE__.handle_after/4, nil)
  end

  @doc """
  Whether `value` is an acceptable `traceparent`: W3C version `00`, lower-case hex,
  non-zero ids.
  """
  @spec valid_traceparent?(term()) :: boolean()
  def valid_traceparent?(value) when is_binary(value), do: Regex.match?(@traceparent, value)
  def valid_traceparent?(_value), do: false

  @doc """
  The current trace context as a `traceparent` value, for rendering
  `<meta name="traceparent">` so the browser's document-load span parents on the
  server span. Returns nil outside a span.
  """
  @spec current_traceparent() :: String.t() | nil
  def current_traceparent do
    case :otel_propagator_text_map.inject([]) do
      headers when is_list(headers) ->
        case List.keyfind(headers, "traceparent", 0) do
          {_key, value} -> value |> to_string()
          nil -> nil
        end

      _other ->
        nil
    end
  catch
    _kind, _reason -> nil
  end

  @doc false
  def handle_before([_, _, _, :exception], _measurements, _meta, _config) do
    FailedSpan.remember()
  end

  def handle_before(event, _measurements, meta, _config) do
    guard(fn ->
      # Correlation first: it can raise, and a context already attached would stay
      # attached with nothing holding its token.
      correlation = begin_correlation(event, meta)
      put_entry(meta, %{token: adopt(event, meta), correlation: correlation})
    end)
  end

  @doc false
  def handle_after(event, _measurements, meta, _config) do
    guard(fn ->
      case List.last(event) do
        :start -> annotate(event, meta)
        _end -> finish(event, meta)
      end
    end)
  end

  # --- Correlation ------------------------------------------------------------

  defp begin_correlation([:phoenix, :live_view, :mount, :start], meta) do
    correlation = Settings.correlation()

    Process.put({__MODULE__, :mount_params_pending}, true)

    if connected?(meta) do
      correlation.start_new()
    else
      # The dead render runs inside the HTTP request, which may already carry an
      # id; only mint one if it does not.
      if is_nil(correlation.current()), do: correlation.start_new()
    end

    :keep
  end

  defp begin_correlation([:phoenix, :live_view, :handle_params, :start], _meta) do
    if Process.delete({__MODULE__, :mount_params_pending}) do
      # handle_params straight after mount is the same action.
      :keep
    else
      new_scope()
    end
  end

  defp begin_correlation(_handle_event, _meta), do: new_scope()

  defp new_scope do
    correlation = Settings.correlation()
    previous = correlation.current()
    correlation.start_new()
    {:restore, previous}
  end

  defp end_correlation(:keep), do: :ok

  defp end_correlation({:restore, previous}) do
    correlation = Settings.correlation()

    cond do
      previous -> correlation.put(previous)
      function_exported?(correlation, :clear, 0) -> correlation.clear()
      true -> :ok
    end

    :ok
  end

  # --- Trace context ------------------------------------------------------------

  defp adopt(event, meta) do
    if Settings.browser_context?() do
      with tp when is_binary(tp) <- traceparent(event, meta),
           true <- valid_traceparent?(tp),
           ctx <- extract(tp) do
        Ctx.attach(ctx)
      else
        _invalid_or_absent -> nil
      end
    end
  end

  # The extracted parent always reads as sampled, so `-00` cannot silence a request.
  # `AshEnterprise.Telemetry.sampler/1` is what stops this forcing sampling.
  defp extract(traceparent) do
    server_decided = binary_part(traceparent, 0, 53) <> "01"
    :otel_propagator_text_map.extract_to(Ctx.new(), [{"traceparent", server_decided}])
  end

  defp traceparent([:phoenix, _live, :handle_event, _start], %{params: %{"_traceparent" => tp}}),
    do: tp

  defp traceparent([:phoenix, :live_view, :mount, _start], %{
         socket: %{private: %{connect_params: %{"_traceparent" => tp}}}
       }),
       do: tp

  defp traceparent(_event, _meta), do: nil

  defp connected?(%{socket: %{transport_pid: pid}}) when is_pid(pid), do: true
  defp connected?(_meta), do: false

  # --- Span attributes -----------------------------------------------------------

  defp annotate([:phoenix, _live, :handle_event, :start], meta) do
    attributes =
      %{
        Attributes.ui_event_name() => meta[:event],
        Attributes.ui_view() => view_name(meta)
      }
      |> Map.merge(resolved_attributes(meta))
      |> clean_attributes()

    OpenTelemetry.Tracer.set_attributes(attributes)
  end

  defp annotate(_event, _meta), do: :ok

  defp view_name(%{component: component}) when is_atom(component) and not is_nil(component),
    do: inspect(component)

  defp view_name(%{socket: %{view: view}}) when is_atom(view) and not is_nil(view),
    do: inspect(view)

  defp view_name(_meta), do: nil

  defp resolved_attributes(meta) do
    with resolver when not is_nil(resolver) <- Settings.event_attributes(),
         event when is_binary(event) <- meta[:event],
         result when is_map(result) <- run_resolver(resolver, event, meta[:params], meta[:socket]) do
      result
    else
      _none -> %{}
    end
  catch
    _kind, _reason -> %{}
  end

  defp run_resolver({module, function, args}, event, params, socket),
    do: apply(module, function, [event, params, socket | args])

  defp run_resolver(fun, event, params, socket) when is_function(fun, 3),
    do: fun.(event, params, socket)

  defp run_resolver(_other, _event, _params, _socket), do: %{}

  defp clean_attributes(attributes) do
    attributes
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      case {Attributes.reserved?(key), attribute_value(value)} do
        {true, _} -> []
        {_, :skip} -> []
        {false, converted} -> [{key, converted}]
      end
    end)
    |> Map.new()
  end

  defp attribute_value(nil), do: :skip
  defp attribute_value(value) when is_boolean(value) or is_number(value), do: value

  defp attribute_value(value) when is_binary(value),
    do: Sanitize.truncate(value, @max_attribute_bytes)

  defp attribute_value(value) when is_atom(value), do: attribute_value(Atom.to_string(value))
  defp attribute_value(_value), do: :skip

  # --- Ending -------------------------------------------------------------------

  defp finish([:phoenix, _live, :mount, :stop], meta), do: release(meta, _end_scope? = false)
  defp finish(_event, meta), do: release(meta, _end_scope? = true)

  defp release(meta, end_scope?) do
    case pop_entry(meta) do
      nil ->
        :ok

      %{token: token, correlation: correlation} ->
        if token, do: Ctx.detach(token)
        if end_scope?, do: end_correlation(correlation)
        :ok
    end
  end

  defp put_entry(meta, entry) do
    case meta[:telemetry_span_context] do
      nil -> if entry.token, do: Ctx.detach(entry.token)
      key -> Process.put({__MODULE__, key}, entry)
    end
  end

  defp pop_entry(meta) do
    case meta[:telemetry_span_context] do
      nil -> nil
      key -> Process.delete({__MODULE__, key})
    end
  end

  # Telemetry detaches a handler that raises, which would silently end correlation
  # for the rest of the VM's life, so nothing is allowed to escape.
  defp guard(fun) do
    _ = fun.()
    :ok
  catch
    _kind, _reason -> :ok
  end
end
