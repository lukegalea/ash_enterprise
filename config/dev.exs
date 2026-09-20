import Config
config :ash, policies: [show_policy_breakdowns?: true]

# --- Dev-loop trace sink (docs/research/trace-storage-dev-to-prod.md §5) -------
#
# The sink is a consumer of the span pipeline, not a competing pipeline: spans
# flow through the ordinary SDK into `AshEnterprise.Telemetry.TraceSink` via
# the SIMPLE processor (the batch processor's default 5s scheduled_delay_ms
# would kill the sub-second read-after-write the dev loop needs — design §1).
#
# Why these two keys and not `processors: [...]`: the SDK merges
# `traces_exporter` into the processor's `exporter` option, and a user-set
# `traces_exporter` overrides processor opts outright (merge_processor_config/4
# in otel_configuration.erl), so `traces_exporter: {Exporter, []}` is the
# spelling the merge rules actually honour.
#
# Setting OTEL_EXPORTER_OTLP_ENDPOINT (config/runtime.exs) overwrites both keys
# with the batch/OTLP wiring — the long-standing dev behaviour, preserved
# untouched — and the sink goes quiet for that boot. No sink → backend
# backfill, ever.
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: {AshEnterprise.Telemetry.TraceSink.Exporter, []}

# Ring bounds (defaults shown; override to shrink for experiments — tests
# shrink them live). See AshEnterprise.Telemetry.TraceSink.
config :ash_enterprise, :trace_sink?, true
config :ash_enterprise, :trace_sink, ring_size: 50, max_spans: 20_000

# Configure your database.
#
# Connection details come from the environment rather than being hardcoded,
# because devenv allocates the Postgres port dynamically -- it asks for 5432 but
# shifts if anything already holds it (a system Postgres, a Docker container,
# a second devenv project). PGHOST/PGPORT are exported by the devenv postgres
# service and are the only trustworthy source. The literals below are fallbacks
# for running outside devenv.
config :ash_enterprise, AshEnterprise.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("DB_NAME", "ash_enterprise_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# --- Hosting this application inside somebody else's database ------------------
#
# Upstream, `mix setup` owns its whole database: it creates `ash_enterprise_dev`,
# puts the simulated legacy estate in `legacy.*` and everything of its own in
# `public`. That is right for the reference app and wrong for the VendorPM POC
# (VPM-10), where the point is to run against the EXISTING `vendorpm` database --
# the one vendorpm-apolloserver's knex migrations own -- so ash_strangler has a
# real legacy schema to strangle rather than a simulated one.
#
# Sharing a database with another migration system is only safe if the two can
# never contend for a table, so this application takes a Postgres schema of its
# own and stays inside it. Three knobs, each defaulting to the upstream
# behaviour, so `mix setup` outside the VendorPM workspace is unchanged:
#
#   DB_NAME              which database to connect to.
#   ASH_SCHEMA           the schema this application OWNS. Every Ash migration
#                        runs in it and `schema_migrations` lives in it, so Ash's
#                        migration history and knex's `vendorpm.knex_migrations`
#                        are separate objects in separate schemas. Unset, tables
#                        land in `public` exactly as before.
#   PG_EXTENSION_SCHEMA  where the host database installed its extensions, if not
#                        `public`. VendorPM's has citext and uuid-ossp in the
#                        `vendorpm` schema, and Ash's `:ci_string` attributes
#                        compile to an unqualified `citext` column type -- so
#                        without this on the search path, migrating fails with
#                        `type "citext" does not exist`.
#
# NOTE the ordering below: the owned schema is FIRST, so an unqualified name
# always resolves to this application's table before the host's. The trade is
# real and deliberate -- a table this application expects but has not created
# could resolve to a same-named legacy one (`users` exists on both sides) rather
# than erroring. Ash creates every table it reads, so that requires a migration
# to have been skipped; VPM-12 removes the trade entirely by declaring `schema`
# on the resources instead of relying on a search path.
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

  # Oban does NOT read Ecto's `migration_default_prefix`: `Oban.Migration.up/1`
  # and the supervisor both default to `prefix: "public"` independently. Set
  # here so the job tables follow the rest of this application's tables instead
  # of being the one thing left in `public`.
  config :ash_enterprise, Oban, prefix: ash_schema
end

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :ash_enterprise, AshEnterpriseWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  #
  # PHX_IP=0.0.0.0 is how the VendorPM POC opts out: the app runs inside a dev
  # container and the port is published from the workspace node, so a loopback
  # bind is unreachable from the thing doing the publishing and the declared
  # port in .sdlc/app.yaml would answer nothing. The default is unchanged.
  http: [
    ip:
      case System.get_env("PHX_IP") do
        nil -> {127, 0, 0, 1}
        addr -> addr |> String.to_charlist() |> :inet.parse_address() |> elem(1)
      end
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "i7tqsl9XG9p5eOzO0WRHPYhfyw/9qsM5Ssp+ow05nxM4ivKRb4bS3XwAbHjTNrIs",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:ash_enterprise, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:ash_enterprise, ~w(--watch)]}
  ]

# ## SSL Support
#
# In order to use HTTPS in development, a self-signed
# certificate can be generated by running the following
# Mix task:
#
#     mix phx.gen.cert
#
# Run `mix help phx.gen.cert` for more information.
#
# The `http:` config above can be replaced with:
#
#     https: [
#       port: 4001,
#       cipher_suite: :strong,
#       keyfile: "priv/cert/selfsigned_key.pem",
#       certfile: "priv/cert/selfsigned.pem"
#     ],
#
# If desired, both `http:` and `https:` keys can be
# configured to run both http and https servers on
# different ports.

# Enable dev routes for dashboard and mailbox
config :ash_enterprise, dev_routes: true, token_signing_secret: "qaZQqvCZKqxY3RCtI+Ofq4CLfBwXHI+r"

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false
