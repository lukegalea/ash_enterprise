import Config
config :ash_enterprise, Oban, testing: :manual
config :ash_enterprise, token_signing_secret: "2W7xIBrAeWb/GPoe4MBvPxA6NFwqqjl0"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# The drain ingests inside its own transaction, and the event appends ride it
# (a finding's evaluation can never reference a projection that did not
# commit). The event log's notifier hooks then fire after_transaction inside
# that still-open transaction — by design here, noise to Ash. The sandbox
# warning adds nothing to a suite that asserts on the committed outcome.
config :ash, warn_on_transaction_hooks?: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# See config/dev.exs for why host and port are read from the environment.
config :ash_enterprise, AshEnterprise.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "ash_enterprise_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# The VendorPM-workspace knobs, mirroring config/dev.exs. Since VPM-12 the
# migration set includes strangler views over the real legacy tables, so the
# test database has to be a restored copy of the legacy dump -- and that dump
# installs its extensions in a non-public schema, so an unqualified `citext`
# (what every `:ci_string` attribute compiles to) cannot resolve without the
# search path below. Env-gated exactly like dev: unset, the test environment
# keeps the upstream behaviour and runs against a blank database.
ash_schema = System.get_env("ASH_SCHEMA")

if ash_schema do
  search_path =
    [ash_schema, "public", System.get_env("PG_EXTENSION_SCHEMA")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(",")

  config :ash_enterprise, AshEnterprise.Repo,
    migration_default_prefix: ash_schema,
    parameters: [search_path: search_path]

  config :ash_enterprise, Oban, prefix: ash_schema
end

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ash_enterprise, AshEnterpriseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "n4HgSJ7vmCW06IRSD6hjs4qCWeiiG8tRpmubymXCcI+b5ytnOVjnk3ZNndtaJYJK",
  server: false

# In test we don't send emails
config :ash_enterprise, AshEnterprise.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The strangler notification bridge is off in tests. `LISTEN` is session state
# and needs a connection outside the pool, which `Ecto.Adapters.SQL.Sandbox` does
# not provide; and a bridge that fires on committed writes has nothing to say in
# a suite where every test rolls back. Tests that need the behaviour drive
# `AshStrangler.Listener.notify/2` directly.
config :ash_enterprise, :legacy_listener?, false

# The trace sink runs in tests: the design (docs/research/trace-storage-dev-to-prod.md
# §5) makes the ring the test-time assertion substrate, so the suite exercises the
# same capture path the dev loop reads. Spans flow through `otel_simple_processor`
# — synchronous export, so a read immediately after an action sees its spans.
# Bounds are the code defaults; tests shrink them live via :trace_sink config.
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: {AshEnterprise.Telemetry.TraceSink.Exporter, []}

config :ash_enterprise, :trace_sink?, true

# The trigger index reads the database at boot, outside any test's checked-out connection,
# which the Ecto SQL sandbox refuses. See `AshEnterprise.Application.trigger_index/0`.
config :ash_enterprise, trigger_index?: false

# The process engine's advance jobs run synchronously, so a test can assert on where a process
# ended up rather than on the fact that a job was enqueued. Timers are still stored rather than
# fired -- `AshBpmn.Runtime.Oban.TestJobs.fire!/2` fires them explicitly, which is what makes an
# escalation test deterministic instead of a sleep.
config :ash_bpmn, oban_testing: :inline

# The projector engine runs no servers in tests. A `Server` drains on its own
# connection outside any test's sandbox transaction, so async findings would be
# invisible (or fatal) to the test that caused them; the compliance tests drive
# `AshCompliance.Testing.drain_sync/2` instead — the same handler, grain and ops
# path, folded inside the caller's transaction. Leader monitors, the PubSub
# listener and the lag probe are all off with the servers.
config :ash_events_projections, start_projectors?: false, start_probe?: false
