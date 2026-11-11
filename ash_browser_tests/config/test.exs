import Config

chromium =
  System.get_env("E2E_CHROMIUM") || System.find_executable("chromium") ||
    raise """
    ash_browser_tests needs a Chromium binary: enter the devenv shell, which provides
    it, or set E2E_CHROMIUM. Playwright's own browser download is not used.
    """

config :phoenix_test,
  otp_app: :ash_browser_tests,
  endpoint: AshBrowserTests.Fixture.Endpoint,
  playwright: [
    browser_pool: :chromium_pool,
    browser_pools: [[id: :chromium_pool, browser: :chromium, size: 2, executable_path: chromium]],
    assets_dir: "./test/playwright",
    timeout: 15_000,
    browser_launch_timeout: 30_000,
    trace: System.get_env("PW_TRACE") == "1"
  ]

config :ash_browser_tests, AshBrowserTests.Fixture.Endpoint,
  url: [host: "127.0.0.1"],
  http: [ip: {127, 0, 0, 1}, port: 0],
  secret_key_base: String.duplicate("b", 64),
  live_view: [signing_salt: "browsertestsalt"],
  server: true,
  pubsub_server: AshBrowserTests.Fixture.PubSub,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: AshBrowserTests.Fixture.ErrorHTML], layout: false]

config :ash_browser_tests, AshBrowserTests.Fixture.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("BROWSER_TESTS_DB", "ash_browser_tests_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 20

config :ash_browser_tests, ecto_repos: [AshBrowserTests.Fixture.Repo]
config :ash_browser_tests, ash_domains: [AshBrowserTests.Fixture.Domain]

# What `AshEnterprise.Telemetry.processors/1` generates, written out because config
# files load before the package compiles.
config :opentelemetry,
  processors: [
    {AshEnterprise.Telemetry.SpanProcessor, %{}},
    {AshEnterprise.Telemetry.TraceSink.Processor, %{}}
  ]

config :ash_enterprise_telemetry, :trace_sink?, true
config :ash_enterprise_telemetry, :trace_sink, ring_size: 5_000, max_spans: 200_000
config :ash_enterprise_telemetry, :browser_ingest, enabled: true, rate_limit: 100_000

config :ash, :tracer, [AshEnterprise.Telemetry.AshTracer]
config :ash, :disable_async?, true
config :ash, default_string_length_count: :codepoints
config :ash, :validate_domain_inclusion?, false

config :logger, level: :warning
config :phoenix, :json_library, Jason
