defmodule AshEnterprise.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    setup_opentelemetry()

    children =
      [
        {AshEnterprise.Hammer, [clean_period: 60_000]},
        AshEnterpriseWeb.Telemetry,
        AshEnterprise.Repo,
        {DNSCluster, query: Application.get_env(:ash_enterprise, :dns_cluster_query) || :ignore},
        {Oban,
         AshOban.config(
           Application.fetch_env!(:ash_enterprise, :ash_domains),
           Application.fetch_env!(:ash_enterprise, Oban)
         )},
        {Phoenix.PubSub, name: AshEnterprise.PubSub},
        # Start a worker by calling: AshEnterprise.Worker.start_link(arg)
        # {AshEnterprise.Worker, arg},
        # Start to serve requests, typically the last entry
        AshEnterpriseWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :ash_enterprise]},
        {Absinthe.Subscription, AshEnterpriseWeb.Endpoint},
        AshGraphql.Subscription.Batcher
      ] ++ legacy_listener()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AshEnterprise.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The bridge that makes a write by the *legacy* application visible here.
  #
  # It listens on a `pg_notify` channel that the trigger on `legacy.users`
  # announces on, re-reads the affected row through Ash, and dispatches a real
  # `Ash.Notifier.Notification` -- which the `pub_sub` block on
  # `AshEnterprise.Legacy.User` then broadcasts, and the A2UI surface refreshes
  # from. See docs/plans/ash-strangler-in-reference-app.md §5, step 3.
  #
  # After the endpoint, because a notification arriving before the endpoint is up
  # has nowhere to broadcast to.
  #
  # `authorize?: false` on the re-read, and it is worth being precise about what
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
        {AshStrangler.Listener,
         repo: AshEnterprise.Repo, resources: [AshEnterprise.Legacy.User], authorize?: false}
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
  defp setup_opentelemetry do
    OpentelemetryPhoenix.setup(adapter: :bandit, liveview: true)
    OpentelemetryEcto.setup([:ash_enterprise, :repo], db_statement: :disabled)
    :ok
  end

  @impl true
  def config_change(changed, _new, removed) do
    AshEnterpriseWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
