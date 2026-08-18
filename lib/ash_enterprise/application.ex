defmodule AshEnterprise.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    setup_opentelemetry()

    children = [
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
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AshEnterprise.Supervisor]
    Supervisor.start_link(children, opts)
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
