import Config

# Chromium comes from devenv (`pkgs.chromium`) by default, `E2E_CHROMIUM=<path>` for
# another binary, or `E2E_CHROMIUM=bundled` for the one `mix playwright.install chromium`
# installs, which is what CI uses.
chromium =
  case System.get_env("E2E_CHROMIUM") do
    "bundled" -> nil
    nil -> System.find_executable("chromium")
    path -> path
  end

config :fluffy,
  endpoint: AshBrowserTests.Fixture.Endpoint,
  ecto_repos: [AshBrowserTests.Fixture.Repo]

# `AshBrowserTests.SandboxHook` reads the sandbox metadata from the user agent.
config :fluffy, Fluffy.Sandbox, header: "user-agent"

config :playwright, :test,
  browser_name: :chromium,
  workers: 2,
  launch_options: [timeout: 90_000] ++ if(chromium, do: [executable_path: chromium], else: []),
  action_timeout: 30_000,
  navigation_timeout: 30_000,
  expect: [timeout: 30_000],
  trace: if(System.get_env("PW_TRACE") == "1", do: :on, else: :retain_on_failure),
  screenshot: :only_on_failure

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
