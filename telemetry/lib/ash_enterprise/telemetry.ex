defmodule AshEnterprise.Telemetry do
  @moduledoc """
  Runtime observability for Ash and Phoenix applications. One call attaches tracing,
  correlation, background-job context and error reporting in the order they depend on.

      # Application.start/2
      AshEnterprise.Telemetry.setup(
        otp_app: :my_app,
        repo_prefixes: [[:my_app, :repo]],
        db_statement: :enabled
      )

  ## Why order matters

  `:telemetry` runs handlers in attach order, and a span is created by a library's own
  handler. So:

    * correlation and browser-context **start** handlers run *before* `OpentelemetryPhoenix`
      and `OpentelemetryOban`, or a span starts with no correlation and no parent;
    * attribute and detach handlers run *after*, or the span does not exist yet at
      start, and at stop the context is detached before the library has closed the span;
    * `OpentelemetryBandit` is attached before `OpentelemetryPhoenix`, so the HTTP span
      exists when Phoenix adds its route to it.

  ## Configuration: use `processors/1`

  Generate the processor list; do not write it by hand:

      # config/runtime.exs
      config :opentelemetry,
        processors:
          AshEnterprise.Telemetry.processors(
            trace_sink: config_env() == :dev,
            otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
          )

  It exists because of three silent failures in the SDK's configuration:

    * **`on_end` short-circuits.** The SDK folds it as
      `Bool andalso P:on_end(Span, Config) =:= true`, so the first processor returning
      anything else skips the rest, with nothing logged. `otel_simple_processor` returns
      its call's reply, which is not `true`, so a simple processor ahead of the batch
      processor sends nothing to OTLP. The batch processor returns `dropped` under
      overload. The list is therefore: `SpanProcessor` and `TraceSink.Processor`, which
      always return `true`, then the batch processor, last, with nothing after it to
      starve.
    * **Exporters are per processor.** Name each on its processor and **never set the
      global `span_processor` or `traces_exporter` keys**: `span_processor` beats
      `processors`, and a global `traces_exporter` overrides every processor's exporter
      (`otel_configuration.erl`), so spans stop reaching one destination.
    * **The exporter appends the signal path itself.** Per-processor `endpoints` and the
      application-level `otlp_endpoint` both get `/v1/traces` added, so a URL that already
      ends in it posts to `/v1/traces/v1/traces`. `processors/1` takes the base URL and
      removes that suffix if it is given one.

  Logs and metrics read their endpoint from the `:opentelemetry_experimental`
  application, not `:opentelemetry_exporter`. Setting `OTEL_EXPORTER_OTLP_ENDPOINT` in
  the environment covers all three signals.

  ## Sampling

  The SDK's default is `always_on`. To sample less, configure it through `sampler/1`, so
  a parent the browser supplied cannot override the root sampler:

      # config/runtime.exs
      config :opentelemetry, sampler: AshEnterprise.Telemetry.sampler({:trace_id_ratio_based, 0.1})

  ## Trace headers from clients

  An incoming `traceparent` and `baggage` are attacker-controlled on a public endpoint.
  With the default `public_endpoint: true` a request starts a new root trace and the
  client's `traceparent` becomes a link, so a client cannot join a trace of its
  choosing, silence its requests with `-00`, or put `baggage` into job meta and outbound
  calls. An internal service whose calls should continue the caller's trace sets
  `public_endpoint: false`, or `{module, function, args}` to decide per request.
  LiveView parenting is separate: see `browser_context`.

  ## The Ash tracer

      config :ash, :tracer, [AshEnterprise.Telemetry.AshTracer]

  ## What the package attaches

  `OpentelemetryBandit`, `OpentelemetryPhoenix` (LiveView on), `OpentelemetryOban`
  (consumer spans linked to their producer), `OpentelemetryEcto` per repo, the Oban
  correlation handlers, the logger filter, and the crash handler.

  See `AshEnterprise.Telemetry.Attributes` for the attribute names, a documented
  contract. See `AshEnterprise.Telemetry.ObanEngine`, `OtlpIngest`, `BrowserContext`,
  `SentryWiring`, `BackgroundProbe` and `TaskContext` for the wiring each one needs.
  """

  alias AshEnterprise.Telemetry.BanditSpans
  alias AshEnterprise.Telemetry.BrowserContext
  alias AshEnterprise.Telemetry.CrashHandler
  alias AshEnterprise.Telemetry.Logging
  alias AshEnterprise.Telemetry.ObanContext
  alias AshEnterprise.Telemetry.PhoenixSpans
  alias AshEnterprise.Telemetry.SentryWiring
  alias AshEnterprise.Telemetry.Settings
  alias AshEnterprise.Telemetry.SpanProcessor
  alias AshEnterprise.Telemetry.TraceSink

  @attached_key {__MODULE__, :attached?}
  @default_dropped_paths ["/otel/v1/traces", "/sentry/tunnel"]

  @schema NimbleOptions.new!(
            otp_app: [
              type: :atom,
              required: true,
              doc: "The host application."
            ],
            repo_prefixes: [
              type: {:list, {:list, :atom}},
              doc: """
              Ecto telemetry prefixes, such as `[[:my_app, :repo]]`. When absent they are
              derived from the host's `:ecto_repos`.
              """
            ],
            correlation: [
              type: :atom,
              default: AshEnterprise.Telemetry.Correlation,
              doc: "A module implementing `AshEnterprise.Telemetry.Correlation`."
            ],
            event_attributes: [
              type: {:or, [:mfa, {:fun, 3}, nil]},
              default: nil,
              doc: """
              Resolves span attributes for a `handle_event`: called with the event name, its
              params and the socket (`{module, function, args}` or a 3-arity function), returning
              a map. Run on every event, and may not raise usefully: a failure is ignored.
              See `AshEnterprise.Telemetry.A2uiEventAttributes`.
              """
            ],
            browser_context: [
              type: :boolean,
              default: false,
              doc: "Adopt the browser's `traceparent`. See `BrowserContext` for the trust model."
            ],
            public_endpoint: [
              type: {:or, [:boolean, :mfa]},
              default: true,
              doc: """
              Treat HTTP callers as untrusted: a client's `traceparent` becomes a link and its
              `baggage` is ignored. `false` continues the caller's trace, for a service only
              reached by internal callers. `{module, function, args}` is called with `(conn, args)`
              and returns whether that request is public.
              """
            ],
            db_statement: [
              type: {:in, [:enabled, :disabled]},
              default: :disabled,
              doc: "Include SQL text on Ecto spans. Queries are parameterized."
            ],
            ash_trace_types: [
              type: {:list, :atom},
              default: [:custom, :action, :flow],
              doc: "Ash span types to record. `:query` and `:calculation` are noisy."
            ],
            oban: [
              type: :boolean,
              default: true,
              doc: "Instrument Oban, with consumer spans linked to their producer."
            ],
            dropped_paths: [
              type: {:list, :string},
              default: @default_dropped_paths,
              doc: "HTTP paths that get no server span, so a browser flush does not trace itself."
            ],
            crash_spans: [
              type: :boolean,
              default: true,
              doc: "Add the logger handler that records process crashes as spans."
            ],
            logger_filter: [
              type: :boolean,
              default: true,
              doc: "Add the logger filter that puts trace ids on log events."
            ],
            otlp_logs: [
              type: {:or, [:boolean, :keyword_list]},
              default: false,
              doc:
                "Add the OTLP log handler; a keyword list is passed to `Logging.add_otlp_handler/1`."
            ],
            sentry: [
              type: :boolean,
              default: false,
              doc: "Add `Sentry.LoggerHandler`. See `SentryWiring` for the config it expects."
            ]
          )

  @doc """
  The span processor list for `config :opentelemetry, processors:`, ordered so no
  destination can starve another. See the moduledoc for why.

  ## Options

    * `:trace_sink` - include the in-VM sink. Default `false`.
    * `:otlp` - include the OTLP batch processor. Default `true`.
    * `:otlp_endpoint` - collector base URL, such as `http://collector:4318`; the
      exporter adds `/v1/traces`. Absent, the exporter reads `OTEL_EXPORTER_OTLP_ENDPOINT`
      or the application-level `otlp_endpoint`.
    * `:otlp_headers` - request headers as a list of `{name, value}`.
    * `:exporter` - replaces the OTLP exporter, as `{module, config}`.
    * `:scheduled_delay_ms` - batch export interval.
  """
  @spec processors(keyword()) :: [{module(), map()}]
  def processors(opts \\ []) do
    sink = if Keyword.get(opts, :trace_sink, false), do: [{TraceSink.Processor, %{}}], else: []
    otlp = if Keyword.get(opts, :otlp, true), do: [batch_processor(opts)], else: []

    [{SpanProcessor, %{}}] ++ sink ++ otlp
  end

  defp batch_processor(opts) do
    config =
      case opts[:scheduled_delay_ms] do
        nil -> %{exporter: exporter(opts)}
        delay -> %{exporter: exporter(opts), scheduled_delay_ms: delay}
      end

    {:otel_batch_processor, config}
  end

  defp exporter(opts) do
    case opts[:exporter] do
      nil -> {:opentelemetry_exporter, exporter_config(opts)}
      exporter -> exporter
    end
  end

  defp exporter_config(opts) do
    %{}
    |> put_endpoint(opts[:otlp_endpoint])
    |> put_headers(opts[:otlp_headers])
  end

  defp put_endpoint(config, nil), do: config
  defp put_endpoint(config, ""), do: config

  defp put_endpoint(config, endpoint) when is_binary(endpoint) do
    base = endpoint |> String.trim_trailing("/") |> String.replace_suffix("/v1/traces", "")
    Map.merge(config, %{protocol: :http_protobuf, endpoints: [base]})
  end

  defp put_headers(config, nil), do: config
  defp put_headers(config, headers), do: Map.put(config, :headers, headers)

  @doc """
  The sampler for `config :opentelemetry, sampler:`.

  Parent-based, with a sampled remote parent sent to `root` as well. The SDK's
  default for that case is `always_on`, and `BrowserContext` presents every browser
  `traceparent` as sampled, so without this any client sending a valid one is traced at
  100% whatever `root` is. Local children still follow their parent, so a trace is
  never cut in half.
  """
  @spec sampler(:otel_sampler.sampler_spec()) :: {:parent_based, map()}
  def sampler(root), do: {:parent_based, %{root: root, remote_parent_sampled: root}}

  @doc false
  @spec default_dropped_paths() :: [String.t()]
  def default_dropped_paths, do: @default_dropped_paths

  @doc false
  @spec bandit_options(keyword()) :: keyword()
  def bandit_options(opts) do
    case opts[:public_endpoint] do
      {_module, _function, _args} = mfa -> [public_endpoint_fn: mfa]
      public? -> [public_endpoint: public?]
    end
  end

  @doc """
  Attaches everything, in the required order. Call it once, from `Application.start/2`.

  A second call does nothing, so a test helper and the application can both call it.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec setup(keyword()) :: :ok
  def setup(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    Settings.put(%{
      correlation: opts[:correlation],
      event_attributes: opts[:event_attributes],
      browser_context?: opts[:browser_context],
      dropped_paths: opts[:dropped_paths]
    })

    Application.put_env(:opentelemetry_ash, :trace_types, opts[:ash_trace_types])

    unless :persistent_term.get(@attached_key, false) do
      attach(opts)
      :persistent_term.put(@attached_key, true)
    end

    :ok
  end

  defp attach(opts) do
    # Before the libraries: these start handlers must run first.
    :ok = BrowserContext.attach_before()
    if opts[:oban], do: :ok = ObanContext.attach_before()

    # Bandit first: Phoenix adds the route to the span Bandit opens.
    :ok = OpentelemetryBandit.setup(bandit_options(opts))
    :ok = BanditSpans.attach()
    :ok = OpentelemetryPhoenix.setup(adapter: :bandit, liveview: true)
    :ok = PhoenixSpans.attach()

    if opts[:oban] do
      :ok = OpentelemetryOban.setup(job: [span_relationship: :link], plugin: :disabled)
      :ok = ObanContext.attach_job_span(:link)
    end

    # After the libraries: attribute handlers need the span to exist, and detach
    # handlers must run once the library has closed it.
    :ok = BrowserContext.attach_after()
    if opts[:oban], do: :ok = ObanContext.attach_after()

    for prefix <- repo_prefixes(opts) do
      :ok = OpentelemetryEcto.setup(prefix, db_statement: opts[:db_statement])
    end

    if opts[:logger_filter], do: :ok = Logging.add_trace_filter()
    if opts[:crash_spans], do: :ok = CrashHandler.add()

    case opts[:otlp_logs] do
      false -> :ok
      true -> :ok = Logging.add_otlp_handler()
      logs_opts -> :ok = Logging.add_otlp_handler(logs_opts)
    end

    if opts[:sentry], do: SentryWiring.add_logger_handler()

    :ok
  end

  defp repo_prefixes(opts) do
    case opts[:repo_prefixes] do
      nil -> derived_prefixes(opts[:otp_app])
      prefixes -> prefixes
    end
  end

  # Mirrors Ecto's default telemetry prefix: the repo module's last segments, snake-cased.
  defp derived_prefixes(otp_app) do
    for repo <- Application.get_env(otp_app, :ecto_repos, []) do
      repo.config()[:telemetry_prefix]
    end
  end
end
