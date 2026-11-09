import Config

# What `AshEnterprise.Telemetry.processors/1` generates, written out because config
# files load before the package compiles. `ProcessorsTest` asserts the two match.
config :opentelemetry,
  processors: [
    {AshEnterprise.Telemetry.SpanProcessor, %{}},
    {AshEnterprise.Telemetry.TraceSink.Processor, %{}},
    {:otel_batch_processor,
     %{exporter: {AshEnterprise.Telemetry.TestOtlpExporter, []}, scheduled_delay_ms: 20}}
  ]

# A reader that only collects when a test asks it to, delivering to a registered
# relay process the metric tests set up.
config :opentelemetry_experimental,
  readers: [
    %{
      module: :otel_metric_reader,
      config: %{
        exporter: {:otel_metric_exporter_pid, {:otel_metric, :ash_telemetry_test_metrics}}
      }
    }
  ]

config :ash_enterprise_telemetry, :trace_sink?, true
config :ash_enterprise_telemetry, :trace_sink, ring_size: 5_000, max_spans: 200_000

config :ash_enterprise_telemetry, :browser_ingest,
  enabled: true,
  rate_limit: 100_000

config :ash, :disable_async?, true
config :ash, :validate_domain_inclusion?, false

config :ash_enterprise_telemetry, ecto_repos: [AshEnterprise.Telemetry.TestRepo]

config :ash_enterprise_telemetry, AshEnterprise.Telemetry.TestRepo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("TELEMETRY_TEST_DB", "ash_enterprise_telemetry_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

config :phoenix, :json_library, Jason

config :ash_enterprise_telemetry, AshEnterprise.Telemetry.TestEndpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "telemetrytestsalt"],
  server: false
