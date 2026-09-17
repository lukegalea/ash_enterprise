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
  #
  # `:ash_strangler_ledger` drains the change ledger the legacy trigger writes. It is its own
  # queue because one poison legacy row rolls its batch back and retries: a queue shared with
  # anything latency-sensitive would inherit that backoff.
  queues: [default: 10, bpmn: 10, ash_strangler_ledger: 10],
  repo: AshEnterprise.Repo,
  plugins: [
    # Rescues jobs left `executing` by a node that died mid-flight. Without it they stay that
    # way forever: `drain_queue` does not pick them up, no other node will claim them, and a
    # process whose advance was orphaned simply stops -- silently, which for a *durable*
    # process engine is the one failure mode that must not be possible. Found by killing a
    # seed run mid-drain and watching three instances stick.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    # Retention. Without a Pruner `oban_jobs` grows forever, and this application feeds it
    # steadily: a cron job per tenant every minute, plus a row for every token advance and
    # every timer. Naming `plugins:` at all suppresses Oban's defaults, so the absence here
    # was not "the default retention" -- it was none.
    #
    # Seven days, not the 60-second default, and the number is a decision rather than a
    # preference. Oban's Pruner deletes `completed`, `cancelled` and `discarded` rows, which
    # for a process engine is exactly the history someone asks about after an incident: *was
    # that escalation cancelled, or did it fire?* A week is long enough to answer that from
    # the job table during the window anyone is still asking.
    #
    # It is deliberately **not** the audit trail. `AshEnterprise.Audit.EventLog` is, and the
    # engine's own `ProcessEvent` rows are; both are permanent and neither is pruned. A job
    # row is execution substrate, and seven days of it is an operational convenience, not a
    # record we promise anybody.
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       # The trigger sweep is the *driver*, not a safety net: the nudge on the audit log is
       # non-transactional and can be lost, so this is what guarantees an event is eventually
       # dispatched. Every minute, one job per tenant that has a published, enabled
       # subscription (the fan-out reads `config :ash_bpmn, trigger_tenants`).
       #
       # Spelled as the literal tuple `AshBpmn.Triggers.SweepWorker.cron_entry()` returns
       # rather than by calling it: this file is evaluated before dependencies are compiled,
       # so a function call into a dep would break the cold `mix setup` path.
       {"* * * * *", AshBpmn.Triggers.CronSweep, queue: :bpmn, max_attempts: 1},
       # The ledger sweep is the *recovery net*, not the driver: the ledger trigger's
       # pg_notify wakes the drain worker promptly, and a wake lost while the listener was
       # down is caught here. Every five minutes; the worker's `unique: [period: 30]`
       # collapses the overlap with wake-driven jobs.
       {"*/5 * * * *", AshEnterprise.Ledger.UserDrainWorker,
        queue: :ash_strangler_ledger, max_attempts: 1}
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
  definition_loader: AshEnterprise.Process.DefinitionLoader,
  # The trigger engine's adapter over the audit log. Every coupling to the log lives there:
  # the streaming cursor protocol, the published event-context contract, the per-chain
  # ordering declaration, and the publish-time audited? check.
  event_source: AshEnterprise.Audit.EventSource,
  # The sweep fans out to one job per tenant, every minute (the crontab above). Enumerated
  # from the data, the same way the prototype's cron sweep did it: every tenant with a
  # published, enabled subscription. Evaluated per call; see
  # `AshEnterprise.Bpmn.Subscription.trigger_tenants/0`.
  trigger_tenants: {AshEnterprise.Bpmn.Subscription, :trigger_tenants, []}

config :ash_decisions, ash_domains: [AshEnterprise.Decisions]

# --- The compliance plane (ADR 0035) -------------------------------------------
#
# `ash_compliance` resolves the repo and table prefix through application env,
# the same pattern `ash_compliance`'s own resources use and the one
# `ash_events_projections` (the projector engine it rides on) demands here: a
# library that must not fork its resources per host reads its wiring from the
# host's config. The `ash_compliance_` prefix keeps the fourteen control-plane
# and data-plane tables namespaced beside `bpmn_*` and `ash_projection_*`.
config :ash_compliance,
  repo: AshEnterprise.Repo,
  table_prefix: "ash_compliance_",
  # The drain-nudge worker fans out to these (the recovery net for a missed
  # PubSub wake). The projector engine has its own list below — same module,
  # two keys, because the two packages ask their own config for it.
  projectors: [AshEnterprise.Compliance.Projector]

# The projector engine: one config for the repo it drains against, the PubSub
# server wake-ups broadcast on, the event log it scans, and the projectors it
# boots. `event_table` names the log table the drain SELECTs — the compliance
# log, not the central audit log (`AshEnterprise.Compliance.EventLog` exists
# precisely because the two are different contracts; see its moduledoc).
config :ash_events_projections,
  repo: AshEnterprise.Repo,
  pubsub: AshEnterprise.PubSub,
  event_log: AshEnterprise.Compliance.EventLog,
  event_table: "compliance_events",
  projectors: [AshEnterprise.Compliance.Projector],
  start_projectors?: true,
  start_probe?: true

# The strangler ledger's wake. The `pg_notify` the ledger trigger emits is
# routed here by `AshStrangler.Listener`; the worker's own cron entry in the
# Oban config above is the sweep that guarantees a missed wake costs delay,
# not delivery.
config :ash_strangler, ledger_drain: {AshEnterprise.Ledger.UserDrainWorker, :nudge}

# The trigger sweep dispatches each event inside its own transaction -- deliberately, so a
# dispatch row and the instance it records are committed together and a crashed sweep replays
# cleanly. Ash cannot send notifications from inside a transaction, so the writes the engine
# makes there produce "missed notification" warnings by design rather than by mistake.
#
# Ignored rather than raised: the notifications in question are PubSub updates for engine
# bookkeeping, and nothing subscribes to them. A *host* write that needed its notification
# would not be happening inside the sweep.
config :ash, :missed_notifications, :ignore

# How `min_length` / `max_length` / `string_length` count a string. Ash 3.33
# requires the choice to be explicit rather than inherited, because the two
# answers disagree about what a length *is*.
#
# `:codepoints` is what SQL counts, so an attribute validated in Elixir and the
# same attribute checked by Postgres agree -- and `max_length` genuinely bounds
# how much gets stored. Under `:mixed` (the old behaviour) Elixir counts
# graphemes while atomic updates defer to the data layer, and since one grapheme
# can carry an unbounded run of combining characters, `max_length` stops being a
# size bound at all. An application that treats its database as the record of
# truth cannot have its own validation disagree with it, so: codepoints.
config :ash, default_string_length_count: :codepoints

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
    AshEnterprise.Process,
    AshEnterprise.Contracts,
    AshEnterprise.Compliance,
    AshEnterprise.LegacyAgent,
    AshEnterprise.CanonicalAgent
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

# A2UI experience layer: task modes (create/view/edit), conditional
# pagination, typed feedback, and the semantic admin catalog. App-wide by
# config -- every surface is `AshA2ui.Standalone`-based, so nothing
# per-surface is needed. Version 2 + `:admin_v1` is the full layer; the
# precedence rules (admin requires v2, selection ignored otherwise) are
# deterministic and tested upstream. See
# docs/adr/0033-experience-layer-adoption.md for the decision and its
# reversibility story.
config :ash_a2ui, experience_version: 2, catalog: :admin_v1

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
