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
      operations_metrics() ++
      bpmn_metrics() ++
      retention_metrics() ++
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
    for domain_name <- [:accounts, :security, :audit, :credentialing],
        action_type <- [:create, :read, :update, :destroy, :action],
        do:
          summary("ash.#{domain_name}.#{action_type}.stop.duration",
            unit: {:native, :millisecond},
            description: "#{action_type} actions in the #{domain_name} domain",
            tags: [:resource_short_name, :action]
          )
  end

  # `ash_operations` events (ADR 0063): one per provider call, one per webhook delivery.
  # Tags are structural only, never a path, id, header or body.
  @doc "The metrics `ash_operations` events feed."
  def operations_metrics do
    [
      summary("operations.request.stop.duration",
        unit: {:native, :millisecond},
        tags: [:provider, :operation, :effect, :reason],
        description: "Provider calls, by operation and outcome"
      ),
      counter("operations.request.stop.count",
        event_name: [:operations, :request, :stop],
        tags: [:provider, :operation, :reason],
        description: "Provider calls"
      ),
      summary("operations.request.stop.attempts",
        event_name: [:operations, :request, :stop],
        measurement: fn _measurements, metadata -> Map.get(metadata, :attempts) end,
        tags: [:provider, :operation],
        description: "Attempts a provider call took, retries included"
      ),
      counter("operations.webhook.received.count",
        event_name: [:operations, :webhook, :received],
        tags: [:provider, :outcome, :status],
        description: "Provider webhook deliveries"
      ),
      summary("operations.webhook.received.bytes",
        tags: [:provider],
        description: "Provider webhook body sizes"
      )
    ]
  end

  # The trigger sweep's own events (`AshBpmn.Triggers.Telemetry`). Lag is per tenant: one
  # series per organization with a sweep, which the reporter's series cap bounds. It is
  # reported because `AshEnterprise.Audit.EventSource` implements `latest_sequence/1`.
  @doc "The metrics the BPMN trigger sweep and its dispatches feed."
  def bpmn_metrics do
    [
      last_value("ash_bpmn.triggers.sweep.lag",
        tags: [:tenant],
        description: "Audit events a tenant's trigger sweep has not read yet"
      ),
      summary("ash_bpmn.triggers.dispatch.start.latency",
        unit: {:native, :millisecond},
        tags: [:kind],
        description: "From an event happening to the dispatch that started its process"
      )
    ]
  end

  # Audit retention's daily run (`AshEnterprise.Audit.RetentionWorker`): the audit events
  # left past the hot window for the next run, and the moves that did not verify. No tags:
  # one series for the deployment.
  @doc "The metrics the daily retention run feeds."
  def retention_metrics do
    [
      last_value("ash_enterprise.audit.retention.backlog",
        description: "Audit events past the hot window that the last retention run left"
      ),
      last_value("ash_enterprise.audit.retention.failed",
        description: "Archive moves the last retention run recorded as failed"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {AshEnterpriseWeb, :count_users, []}
    ]
  end
end
