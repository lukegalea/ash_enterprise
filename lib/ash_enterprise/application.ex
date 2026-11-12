defmodule AshEnterprise.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    setup_opentelemetry()
    AshEnterprise.Telemetry.Operations.attach()
    check_external_binaries()
    configure_acp_agent_info()

    children =
      [
        {AshEnterprise.Hammer, [clean_period: 60_000]},
        AshEnterpriseWeb.Telemetry,
        AshEnterprise.Repo,
        # The evidence substrate's repo (AST-152): package-owned module on
        # this host's database — the adjudication orchestrator joins its
        # packets to the host's ledger rows. See config/config.exs.
        AshEvidence.Repo,
        {DNSCluster, query: Application.get_env(:ash_enterprise, :dns_cluster_query) || :ignore},
        {Oban,
         AshOban.config(
           Application.fetch_env!(:ash_enterprise, :ash_domains),
           Application.fetch_env!(:ash_enterprise, Oban)
         )},
        {Phoenix.PubSub, name: AshEnterprise.PubSub},
        # Fire-and-forget OpenLineage posts (AshEnterprise.Lineage.Transport).
        # Supervised per Iron Law #14: a crash in a lineage POST must never
        # take a caller down with it, and the supervisor isolates exactly that.
        {Task.Supervisor, name: AshEnterprise.TaskSupervisor},
        # The lineage store: buffers every RunEvent off the writer's path and
        # writes them in batches (AshEnterprise.Lineage.Store). After the Repo
        # and PubSub, which a flush writes to and broadcasts on.
        AshEnterprise.Lineage.Store,
        # Owns the ACP session/approval ETS tables so they outlive
        # any transient handler process.
        AshEnterprise.Acp.Store,
        # The fake credential registry's memory of the activations it accepted
        # (AshEnterprise.Credentialing.Registry, served over HTTP by its
        # FakeProvider): an ETS table that outlives the job processes that
        # write to it.
        AshEnterprise.Credentialing.Registry,
        # The OMP coding-agent bridge. The registry names one OmpSession per run
        # id; the dynamic supervisor owns the sessions themselves — children
        # are operator events, not boot-time facts.
        {Registry, keys: :unique, name: AshEnterprise.Agents.Registry},
        AshEnterprise.Agents.OmpSupervisor,
        # Wave 2 (ADR 0062): the planning kernel. The registry names one
        # SolverSession per run id; the dynamic supervisor owns the sessions —
        # children are solve events, not boot-time facts (heavy-solve slot
        # is a unique registry key, so it is race-free and self-releasing).
        AshEnterprise.Planning.Registry,
        AshEnterprise.Planning.SessionSupervisor,
        # The trigger index. Started after the Repo because it loads published triggers.
        # Start a worker by calling: AshEnterprise.Worker.start_link(arg)
        # {AshEnterprise.Worker, arg},
        # Start to serve requests, typically the last entry
        AshEnterpriseWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :ash_enterprise]},
        {Absinthe.Subscription, AshEnterpriseWeb.Endpoint},
        AshGraphql.Subscription.Batcher,
        # The projector engine. Boots one leader-monitored `Server` per
        # configured projector (`config :ash_events_projections, projectors:`),
        # so the KYC finding projection drains cluster-wide with automatic
        # failover. After PubSub, because the engine's PubSubListener subscribes
        # to the wake topic. Off in :test — see config/test.exs.
        AshEvents.Projections.Supervisor
      ] ++
        orphans_sweep() ++
        planning_orphans_sweep() ++
        trigger_index() ++ legacy_listener() ++ privilege_sync()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AshEnterprise.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The bridge that makes a write by the *legacy* application visible here.
  #
  # `Legacy.User` has `ledger?(true)`, so the trigger on `legacy.users` is the
  # ledger trigger: it writes a durable `legacy_change_events` row and sends
  # only `wake:<id>` on the `pg_notify` channel. For a wake this listener does
  # one thing -- it nudges `AshEnterprise.Ledger.UserDrainWorker` -- and builds
  # no `Ash.Notifier.Notification`. The drain ingests the event, and once its
  # batch has committed `AshEnterprise.Ledger.UserAnnouncer` dispatches the
  # notification (via `AshStrangler.Listener.notify/2`, which re-reads the row
  # through Ash) that the `pub_sub` block on `AshEnterprise.Legacy.User`
  # broadcasts and the A2UI surface refreshes from. A payload-carrying notify
  # trigger would be handled by this listener directly, but the ledger replaced
  # it. See ADR 0031's addendum and docs/plans/ash-strangler-in-reference-app.md §5.
  #
  # After the endpoint, because a notification arriving before the endpoint is up
  # has nowhere to broadcast to.
  #
  # `authorize?: false` on the re-read (the announcer passes the same option to
  # `AshStrangler.Listener.notify/2`), and it is worth being precise about what
  # that does and does not permit. The listener is not acting for anybody: a
  # legacy `UPDATE` has no Ash actor behind it, so with policies enforced the
  # re-read is simply forbidden and no notification is ever dispatched -- silently,
  # since there is no request to fail. What the notification carries is the fact
  # that a row changed. Every consumer that renders it re-reads under its own
  # actor: the A2UI surface rebuilds its data model with the signed-in user, so
  # the rows a viewer sees are still exactly the rows their policies allow.
  #
  # Off in :test. `LISTEN` needs a connection outside the pool, which the Ecto
  # SQL sandbox does not provide, and a listener that fires on committed writes is
  # meaningless in a suite where every test rolls back.
  defp legacy_listener do
    if Application.get_env(:ash_enterprise, :legacy_listener?, true) do
      [
        {
          AshStrangler.Listener,
          # Every resource whose strangler source declares `notify?(true)` and
          # whose legacy table carries the generated payload-carrying AFTER trigger.
          # That payload names the resource; anything absent from this list is
          # silently dropped by the listener, which is exactly how a surface
          # that used to update stops updating. `legacy.users` carries the
          # ledger trigger (strangler_ledger_legacy_users) instead -- the old
          # strangler_users_notify trigger is dropped -- so today the list
          # only matters to a resource without `ledger?`.
          repo: AshEnterprise.Repo,
          authorize?: false,
          resources: [
            AshEnterprise.Legacy.User
          ]
        }
      ]
    else
      []
    end
  end

  # Brings the privilege catalogue and each tenant's Administrator grants up to
  # this build's resources, once per boot, off the boot path. See
  # AshEnterprise.Platform.PrivilegeSync. Off in :test, where every test seeds
  # inside its own sandbox and a boot-time writer would race them.
  defp privilege_sync do
    if Application.get_env(:ash_enterprise, :privilege_sync?, true) do
      [AshEnterprise.Platform.PrivilegeSync]
    else
      []
    end
  end

  # The bpmn trigger engine's interest index: which resources any published, enabled
  # subscription watches, so the nudge on the audit log can answer "does anyone care about
  # this write" without a query.
  #
  # Off in :test, for the same shape of reason the legacy listener is. It reads the database
  # at boot, outside any test's checked-out connection, so the Ecto SQL sandbox refuses it --
  # and the refusal is harmless but noisy. It is also pointless there: the index exists to
  # save a job insert per write, and a suite that rolls back has nothing to save.
  #
  # `Index.interested?/2` returns false when the table is absent, so the nudge degrades to
  # "nudge nobody" rather than to an error. Dispatch is unaffected either way, because the
  # cron sweep is the driver and the nudge only shortens the wait. Prompt invalidation after
  # a subscription lifecycle write is `Changes.RefreshTriggerIndex` on
  # `AshEnterprise.Bpmn.Subscription`; this process's TTL is the backstop.
  defp trigger_index do
    if Application.get_env(:ash_enterprise, :trigger_index?, true) do
      [AshBpmn.Triggers.Index]
    else
      []
    end
  end

  # The OMP bridge's orphan sweep (see AshEnterprise.Agents.OmpSession). The
  # registry it checks is LOCAL: with several BEAMs sharing one database,
  # leave this off everywhere but the "real" instance.
  defp orphans_sweep do
    if Application.get_env(:ash_enterprise, :agents, [])
       |> Keyword.get(:sweep_orphans_on_boot?, true) do
      [{Task, &AshEnterprise.Agents.OmpSession.fail_orphaned_runs/0}]
    else
      []
    end
  end

  # The planning kernel's orphan sweep (see AshEnterprise.Planning.LeaseSweeper): runs left
  # started with no outcome by a previous BEAM are ended. Same local-registry caveat as above.
  defp planning_orphans_sweep do
    if Application.get_env(:ash_enterprise, :planning, [])
       |> Keyword.get(:sweep_orphans_on_boot?, true) do
      [
        Supervisor.child_spec({Task, &AshEnterprise.Planning.LeaseSweeper.sweep_orphans/0},
          id: :planning_orphans_sweep
        )
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.

  # `opentelemetry_ash` is wired declaratively (`config :ash, :tracer`), but the
  # Phoenix and Ecto instrumentation are :telemetry handlers that must be attached
  # at boot. Without these two calls both dependencies are inert -- they compile,
  # they appear in `mix.lock`, and they produce no spans at all, which is a
  # failure mode that looks exactly like working instrumentation with no traffic.
  #
  # `adapter: :bandit` is required and must match the endpoint's actual adapter;
  # naming the wrong one attaches handlers to telemetry events that never fire.
  # External binaries this application shells out to, and what breaks without each.
  #
  # An absent external dependency should fail **once, loudly, at boot** -- not per-operation
  # and in the vocabulary of the operation. `boxic_dmn`, under `ash_decisions`, validates a DMN
  # document against the normative XSD by running `xmllint`; without it every model fails to
  # load with `:schema_validator_unavailable`, which reads as "decisions are broken" and sends
  # whoever is on call reading decision code rather than installing a package.
  #
  # A warning rather than a refusal to start: an application that does not evaluate decisions
  # is perfectly usable without it, and a hard failure would make an optional feature a boot
  # requirement. The line is written so that searching for the error it prevents finds it.
  @external_binaries [
    {"xmllint",
     "DMN models cannot be validated or loaded (ash_decisions -> boxic_dmn). " <>
       "Install libxml2; in this repository it is `libxml2.bin` in devenv.nix."}
  ]

  # ash_acp reads the `agentInfo` it answers `initialize` with from its own env,
  # and the name in it is the deployment's (`AshEnterprise.Brand`), which is
  # only known at runtime. Set here, before any ACP connection can exist, so the
  # attach bridge and `mix ash_acp.stdio` agree. An explicit `config :ash_acp,
  # agent_info:` still wins.
  defp configure_acp_agent_info do
    if is_nil(Application.get_env(:ash_acp, :agent_info)) do
      Application.put_env(:ash_acp, :agent_info, AshEnterprise.Brand.acp_agent_info())
    end
  end

  defp check_external_binaries do
    for {binary, consequence} <- @external_binaries, is_nil(System.find_executable(binary)) do
      Logger.warning("#{binary} is not on PATH. #{consequence}")
    end

    :ok
  end

  defp setup_opentelemetry do
    AshEnterprise.Telemetry.setup(
      otp_app: :ash_enterprise,
      repo_prefixes: [[:ash_enterprise, :repo]],
      correlation: AshEnterprise.Platform.TelemetryCorrelation,
      db_statement: :disabled
    )

    # Agent steps, tool executions and model calls, as GenAI spans.
    AshEnterprise.Telemetry.GenAI.attach()

    # How far behind each tenant's trigger sweep is.
    AshEnterprise.Bpmn.Telemetry.attach()
  end

  @impl true
  def config_change(changed, _new, removed) do
    AshEnterpriseWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
