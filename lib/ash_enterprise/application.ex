defmodule AshEnterprise.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {AshEnterprise.Hammer, [clean_period: 60000]},
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
  @impl true
  def config_change(changed, _new, removed) do
    AshEnterpriseWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
