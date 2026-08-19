# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mdex_native, syntax_highlighter: :lumis
config :cinder, default_theme: "daisy_ui"
config :ash_oban, pro?: false

config :ash_enterprise, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  # `:bpmn` is where the process engine runs. Every token advance, every timer and the
  # reconciliation sweep are jobs on it, so a stuck queue is a stuck process rather than a
  # slow one -- which is why it is separate from `:default` and not sharing its budget with
  # whatever else the application enqueues.
  queues: [default: 10, bpmn: 10],
  repo: AshEnterprise.Repo,
  plugins: [
    # Rescues jobs left `executing` by a node that died mid-flight. Without it they stay that
    # way forever: `drain_queue` does not pick them up, no other node will claim them, and a
    # process whose advance was orphaned simply stops -- silently, which for a *durable*
    # process engine is the one failure mode that must not be possible. Found by killing a
    # seed run mid-drain and watching three instances stick.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    {Oban.Plugins.Cron,
     crontab: [
       # The trigger sweep is the *driver*, not a safety net: the notifier's nudge is
       # non-transactional and can be lost, so this is what guarantees an event is eventually
       # dispatched. Every minute, one job per tenant that has a published trigger.
       {"* * * * *", AshEnterprise.Process.Triggers.CronSweep}
     ]}
  ]

# --- The process engine's three host callbacks --------------------------------
#
# `ash_bpmn` deliberately knows nothing about what an action is, who a manager is, or what a
# decision is. Each is a module here, and each is the seam that keeps business logic out of
# the process graph: a rule expressed in a diagram is a rule every non-process caller
# bypasses.
config :ash_bpmn,
  ash_domains: [AshEnterprise.Bpmn],
  assignment_resolver: AshEnterprise.Process.AssignmentResolver,
  action_invoker: AshEnterprise.Process.ActionInvoker,
  decision_resolver: AshEnterprise.Process.DecisionResolver,
  # Without this the engine reads an instance's definition in the instance's own tenant, which
  # cannot see a platform baseline -- and the failure is silent: the token claims and the
  # process sits at its start node forever.
  definition_loader: AshEnterprise.Process.DefinitionLoader

config :ash_decisions, ash_domains: [AshEnterprise.Decisions]

# The trigger sweep dispatches a whole batch inside one transaction -- deliberately, so a
# dispatch row and the instance it records are committed together and a crashed sweep replays
# cleanly. Ash cannot send notifications from inside a transaction, so the writes the engine
# makes there produce "missed notification" warnings by design rather than by mistake.
#
# Ignored rather than raised: the notifications in question are PubSub updates for engine
# bookkeeping, and nothing subscribes to them. A *host* write that needed its notification
# would not be happening inside the sweep.
config :ash, :missed_notifications, :ignore

config :ash_graphql, authorize_update_destroy_with_error?: true

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec, AshMoney.Types.Money],
  custom_types: [money: AshMoney.Types.Money]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :rate_limit,
        :graphql,
        :json_api,
        :admin,
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :graphql,
        :json_api,
        :admin,
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

# --- Observability -----------------------------------------------------------
#
# OpentelemetryAsh implements Ash.Tracer, so every action, query, changeset,
# validation, change and calculation becomes a span with no per-resource wiring.
# That is the same "declare once, derive everywhere" property as the rest of the
# platform: a new resource is instrumented by virtue of being a resource.
#
# Note the honest limitation recorded in
# docs/manifesto/07-what-we-do-not-have.md: opentelemetry_ash is 0.1.x and thin
# relative to what enterprise APM expects. Expect to extend it.
config :ash, :tracer, [OpentelemetryAsh]

# Traces go nowhere unless an OTLP endpoint is configured, which is the right
# default for a template: exporting by accident is worse than not exporting.
# Set OTEL_EXPORTER_OTLP_ENDPOINT to turn it on (see config/runtime.exs).
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :none

# Teach Postgrex about the pgvector wire type. See lib/ash_enterprise/postgrex_types.ex.
config :ash_enterprise, AshEnterprise.Repo, types: AshEnterprise.PostgrexTypes

config :ash_enterprise,
  ecto_repos: [AshEnterprise.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    AshEnterprise.Legacy,
    AshEnterprise.Legacy.Twins,
    AshEnterprise.Accounts,
    AshEnterprise.Security,
    AshEnterprise.Audit,
    AshEnterprise.Reference,
    AshEnterprise.Bpmn,
    AshEnterprise.Decisions,
    AshEnterprise.Process
  ],
  base_resources: [AshEnterprise.Platform.Resource]

# Configure the endpoint
config :ash_enterprise, AshEnterpriseWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AshEnterpriseWeb.ErrorHTML, json: AshEnterpriseWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AshEnterprise.PubSub,
  live_view: [signing_salt: "B+Adr/Rm"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ash_enterprise, AshEnterprise.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ash_enterprise: [
    # bpmn-js ships an icon font and its stylesheet references the files by relative path.
    # Without loaders esbuild fails outright on the unresolved `.woff` -- it is not a
    # cosmetic gap, the build stops. Inlined as data URLs, which `font-src 'self' data:`
    # in the CSP already permits, so the diagram palette renders without widening it.
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.) ++
        ~w(--loader:.woff=dataurl --loader:.woff2=dataurl --loader:.ttf=dataurl
           --loader:.eot=dataurl --loader:.svg=dataurl),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path(),
        # The ash_bpmn hook lives in `deps/ash_bpmn/priv/js/` and imports `bpmn-js`, which is
        # installed here. Node resolution walks up from the *importing file*, so without this
        # it searches `deps/ash_bpmn/node_modules` and upwards and never reaches the assets
        # directory -- the build fails outright rather than degrading.
        Path.expand("../assets/node_modules", __DIR__)
      ]
    }
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  ash_enterprise: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path(),
        # The ash_bpmn hook lives in `deps/ash_bpmn/priv/js/` and imports `bpmn-js`, which is
        # installed here. Node resolution walks up from the *importing file*, so without this
        # it searches `deps/ash_bpmn/node_modules` and upwards and never reaches the assets
        # directory -- the build fails outright rather than degrading.
        Path.expand("../assets/node_modules", __DIR__)
      ]
    }
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# ex_money (via ash_money). Do not auto-start the exchange-rate retriever:
# starting it implicitly is deprecated upstream, and an enterprise system wants
# FX rates to be a deliberate, auditable data source rather than a background
# HTTP poll nobody configured. If you need live rates, set this to true or add
# `Money.ExchangeRates.Retriever` to the supervision tree in application.ex.
# ex_money ships its own default CLDR backend (Money.Cldr), which is fine until
# you need locales beyond en. At that point add {:ex_cldr, "~> 2.0"} and define
# a project backend, so the compiled locale set is under your control.
config :ex_money, auto_start_exchange_rate_service: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
