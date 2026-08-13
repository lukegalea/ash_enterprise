defmodule AshEnterpriseWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    ash_metrics() ++
      [
        # Phoenix Metrics
        summary("phoenix.endpoint.start.system_time",
          unit: {:native, :millisecond}
        ),
        summary("phoenix.endpoint.stop.duration",
          unit: {:native, :millisecond}
        ),
        summary("phoenix.router_dispatch.start.system_time",
          tags: [:route],
          unit: {:native, :millisecond}
        ),
        summary("phoenix.router_dispatch.exception.duration",
          tags: [:route],
          unit: {:native, :millisecond}
        ),
        summary("phoenix.router_dispatch.stop.duration",
          tags: [:route],
          unit: {:native, :millisecond}
        ),
        summary("phoenix.socket_connected.duration",
          unit: {:native, :millisecond}
        ),
        sum("phoenix.socket_drain.count"),
        summary("phoenix.channel_joined.duration",
          unit: {:native, :millisecond}
        ),
        summary("phoenix.channel_handled_in.duration",
          tags: [:event],
          unit: {:native, :millisecond}
        ),

        # Database Metrics
        summary("ash_enterprise.repo.query.total_time",
          unit: {:native, :millisecond},
          description: "The sum of the other measurements"
        ),
        summary("ash_enterprise.repo.query.decode_time",
          unit: {:native, :millisecond},
          description: "The time spent decoding the data received from the database"
        ),
        summary("ash_enterprise.repo.query.query_time",
          unit: {:native, :millisecond},
          description: "The time spent executing the query"
        ),
        summary("ash_enterprise.repo.query.queue_time",
          unit: {:native, :millisecond},
          description: "The time spent waiting for a database connection"
        ),
        summary("ash_enterprise.repo.query.idle_time",
          unit: {:native, :millisecond},
          description:
            "The time the connection spent waiting before being checked out for the query"
        ),

        # VM Metrics
        summary("vm.memory.total", unit: {:byte, :kilobyte}),
        summary("vm.total_run_queue_lengths.total"),
        summary("vm.total_run_queue_lengths.cpu"),
        summary("vm.total_run_queue_lengths.io")
      ]
  end

  # Ash emits `[:ash, <domain_short_name>, <action_type>]` telemetry for every
  # action, plus lower-level events for changesets, queries, validations,
  # changes and calculations.
  #
  # These are declared per DOMAIN rather than per resource, because that is the
  # granularity Ash emits at -- and it is the useful one: "reads in Security are
  # slow" is actionable, while a metric per resource per action is a dashboard
  # nobody reads.
  #
  # Adding a resource to an existing domain needs no change here. Adding a
  # DOMAIN does, which is the one place this is not automatic.
  defp ash_metrics do
    for domain_name <- [:accounts, :security, :audit],
        action_type <- [:create, :read, :update, :destroy, :action],
        do:
          summary("ash.#{domain_name}.#{action_type}.stop.duration",
            unit: {:native, :millisecond},
            description: "#{action_type} actions in the #{domain_name} domain",
            tags: [:resource_short_name, :action]
          )
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {AshEnterpriseWeb, :count_users, []}
    ]
  end
end
