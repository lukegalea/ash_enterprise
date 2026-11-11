defmodule AshEnterprise.Telemetry.Metrics do
  @moduledoc """
  Exports `Telemetry.Metrics` definitions as OTLP metrics, and the BEAM's own metrics
  (`AshEnterprise.Telemetry.VmMetrics`) beside them.

  A Phoenix application already lists its metrics (the generated `MyAppWeb.Telemetry`
  module); without a reporter they go nowhere. Add this as that supervisor's reporter:

      children = [
        {AshEnterprise.Telemetry.Metrics, metrics: metrics()}
      ]

  The OTLP export needs a metric reader (`config :opentelemetry_experimental, readers:`,
  see the package README); without one the instruments record into nothing.

  ## Mapping

  | `Telemetry.Metrics` | OpenTelemetry instrument |
  |---|---|
  | `counter` | counter, adding 1 per event |
  | `sum` | up-down counter, adding the measurement |
  | `last_value` | observable gauge of the latest measurement per tag set |
  | `summary`, `distribution` | histogram; `reporter_options: [buckets: [...]]` sets the bucket boundaries |

  The name is the metric's name joined with dots (`phoenix.router_dispatch.stop.duration`),
  the unit its converted unit (`{:native, :millisecond}` exports milliseconds as `ms`), the
  attributes its tags. Tags are the only attributes, so cardinality is what the metric
  definitions allow: tag a route, a queue or a LiveView module, never an id or a path.
  `:max_series` (default 1,000 per metric) drops new tag sets beyond it. A tag whose value
  is a module exports its name without the `Elixir.` prefix.

  ## A standard set

  `standard/1` returns definitions for Phoenix, LiveView, Ecto, Ash and Oban under fixed
  names, the names the provisioned dashboards read. A host adds its own beside them:

      {AshEnterprise.Telemetry.Metrics,
       metrics:
         AshEnterprise.Telemetry.Metrics.standard(
           repos: [[:my_app, :repo]],
           ash_domains: Application.fetch_env!(:my_app, :ash_domains)
         ) ++ my_own_metrics()}

  | Metric | Unit | Attributes |
  |---|---|---|
  | `phoenix.endpoint.stop.duration` | ms | |
  | `phoenix.router_dispatch.stop.duration` | ms | `route` |
  | `phoenix.router_dispatch.exception.count` | | `route` |
  | `phoenix.live_view.mount.stop.duration` | ms | `view` |
  | `phoenix.live_view.handle_event.stop.duration` | ms | `view`, `event` |
  | `phoenix.live_view.handle_event.exception.count` | | `view`, `event` |
  | `ecto.query.total_time`, `ecto.query.queue_time` | ms | `repo`, `source` |
  | `ash.action.duration` | ms | `domain`, `resource`, `action_type`, `action` |
  | `oban.job.duration` | ms | `queue`, `worker`, `state` |
  | `oban.job.exception.count` | | `queue`, `worker` |

  ## Options

    * `:metrics` - the `Telemetry.Metrics` definitions.
    * `:vm` - also start `AshEnterprise.Telemetry.VmMetrics`. Default `true`.
    * `:max_series` - tag sets kept per metric. Default 1,000.
  """

  use Supervisor

  alias AshEnterprise.Telemetry.Metrics.Reporter
  alias AshEnterprise.Telemetry.VmMetrics

  @buckets [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  @doc """
  The standard definitions described above. Options: `:repos` (each repo's telemetry
  prefix, `[:my_app, :repo]`), `:ash_domains` (the domain modules), and `:phoenix`,
  `:live_view`, `:oban` (each `true` by default).
  """
  @spec standard(keyword()) :: [Telemetry.Metrics.t()]
  def standard(opts \\ []) do
    phoenix = if Keyword.get(opts, :phoenix, true), do: phoenix(), else: []
    live_view = if Keyword.get(opts, :live_view, true), do: live_view(), else: []
    oban = if Keyword.get(opts, :oban, true), do: oban(), else: []
    repos = Enum.flat_map(Keyword.get(opts, :repos, []), &repo/1)
    ash = Enum.flat_map(Keyword.get(opts, :ash_domains, []), &ash/1)

    phoenix ++ live_view ++ repos ++ ash ++ oban
  end

  defp histogram(name, opts) do
    Telemetry.Metrics.distribution(
      name,
      [unit: {:native, :millisecond}, reporter_options: [buckets: @buckets]] ++ opts
    )
  end

  defp phoenix do
    [
      histogram("phoenix.endpoint.stop.duration", []),
      histogram("phoenix.router_dispatch.stop.duration", tags: [:route]),
      Telemetry.Metrics.counter("phoenix.router_dispatch.exception.count",
        event_name: [:phoenix, :router_dispatch, :exception],
        tags: [:route]
      )
    ]
  end

  defp live_view do
    view = fn meta -> Map.put(meta, :view, view(meta)) end

    [
      histogram("phoenix.live_view.mount.stop.duration", tags: [:view], tag_values: view),
      histogram("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        tag_values: view
      ),
      Telemetry.Metrics.counter("phoenix.live_view.handle_event.exception.count",
        event_name: [:phoenix, :live_view, :handle_event, :exception],
        tags: [:view, :event],
        tag_values: view
      )
    ]
  end

  defp view(%{socket: %{view: view}}), do: view
  defp view(_meta), do: nil

  defp repo(prefix) do
    repo = Enum.map_join(prefix, ".", &Atom.to_string/1)
    tag_values = fn meta -> meta |> Map.put(:repo, repo) |> Map.put_new(:source, nil) end

    for measurement <- [:total_time, :queue_time] do
      histogram("ecto.query.#{measurement}",
        event_name: prefix ++ [:query],
        measurement: measurement,
        tags: [:repo, :source],
        tag_values: tag_values
      )
    end
  end

  # Ash emits `[:ash, <domain short name>, <action type>, :stop]` per action.
  defp ash(domain) do
    domain_name = Ash.Domain.Info.short_name(domain)

    for action_type <- [:create, :read, :update, :destroy, :action] do
      histogram("ash.action.duration",
        event_name: [:ash, domain_name, action_type, :stop],
        measurement: :duration,
        tags: [:domain, :resource, :action_type, :action],
        tag_values: fn meta ->
          %{
            domain: Atom.to_string(domain_name),
            resource: meta[:resource_short_name],
            action_type: Atom.to_string(action_type),
            action: action_name(meta[:action])
          }
        end
      )
    end
  end

  defp action_name(%{name: name}), do: name
  defp action_name(name) when is_atom(name), do: name
  defp action_name(_other), do: nil

  defp oban do
    [
      histogram("oban.job.duration",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        tags: [:queue, :worker, :state],
        tag_values: &oban_tags/1
      ),
      Telemetry.Metrics.counter("oban.job.exception.count",
        event_name: [:oban, :job, :exception],
        tags: [:queue, :worker],
        tag_values: &oban_tags/1
      )
    ]
  end

  defp oban_tags(%{job: job} = meta),
    do: %{queue: job.queue, worker: job.worker, state: meta[:state]}

  defp oban_tags(meta), do: meta

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    vm = if Keyword.get(opts, :vm, true), do: [VmMetrics], else: []
    Supervisor.init([{Reporter, opts} | vm], strategy: :one_for_one)
  end
end
