defmodule AshEnterprise.Telemetry.MetricsTest do
  # The metric exporter sends to one registered name, and the reporter and the VM
  # metrics are named singletons.
  use ExUnit.Case, async: false

  import Telemetry.Metrics

  require Record

  # Prefixed: `sum` and `counter` are also Telemetry.Metrics functions.
  for name <- [:metric, :sum, :gauge, :histogram, :datapoint, :histogram_datapoint] do
    Record.defrecordp(
      :"otel_#{name}",
      name,
      Record.extract(name, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
    )
  end

  setup do
    Process.register(self(), :ash_telemetry_test_metrics)
    :ok
  end

  defp collect do
    :otel_meter_server.force_flush()
    drain(%{})
  end

  defp drain(acc) do
    receive do
      {:otel_metric, record} -> drain(Map.put(acc, otel_metric(record, :name), record))
    after
      100 -> acc
    end
  end

  defp points(record) do
    case otel_metric(record, :data) do
      data when Record.is_record(data, :sum) -> otel_sum(data, :datapoints)
      data when Record.is_record(data, :gauge) -> otel_gauge(data, :datapoints)
      data when Record.is_record(data, :histogram) -> otel_histogram(data, :datapoints)
    end
  end

  defp values(metrics, name) do
    metrics
    |> Map.fetch!(name)
    |> points()
    |> Map.new(fn
      point when Record.is_record(point, :datapoint) ->
        {otel_datapoint(point, :attributes), otel_datapoint(point, :value)}

      point ->
        {otel_histogram_datapoint(point, :attributes),
         {otel_histogram_datapoint(point, :count), otel_histogram_datapoint(point, :sum)}}
    end)
  end

  test "Telemetry.Metrics definitions are exported as OTLP instruments" do
    suffix = System.unique_integer([:positive])
    event = [:metrics_test, :"run#{suffix}", :stop]
    prefix = "metrics_test.run#{suffix}.stop"

    start_supervised!(
      {AshEnterprise.Telemetry.Metrics,
       vm: false,
       metrics: [
         counter(event ++ [:count], tags: [:route]),
         sum(event ++ [:bytes], unit: :byte),
         last_value(event ++ [:depth], tags: [:queue]),
         summary(event ++ [:duration],
           unit: {:native, :millisecond},
           tags: [:module],
           reporter_options: [buckets: [1, 10, 100]]
         ),
         counter(event ++ [:kept], keep: &(&1[:route] == "/kept"))
       ]}
    )

    for route <- ["/a", "/a", "/kept"] do
      :telemetry.execute(
        event,
        %{
          count: 1,
          bytes: 5,
          depth: 3,
          duration: System.convert_time_unit(20, :millisecond, :native),
          kept: 1
        },
        %{route: route, queue: "q", module: __MODULE__}
      )
    end

    metrics = collect()

    assert values(metrics, :"#{prefix}.count") == %{
             %{route: "/a"} => 2,
             %{route: "/kept"} => 1
           }

    assert values(metrics, :"#{prefix}.bytes") == %{%{} => 15}
    assert values(metrics, :"#{prefix}.depth") == %{%{queue: "q"} => 3}
    assert otel_metric(metrics[:"#{prefix}.duration"], :unit) == :ms

    assert %{%{module: "AshEnterprise.Telemetry.MetricsTest"} => {3, sum}} =
             values(metrics, :"#{prefix}.duration")

    assert_in_delta sum, 60, 1
    assert values(metrics, :"#{prefix}.kept") == %{%{} => 1}
  end

  test "the standard set records Phoenix, LiveView, Ecto, Ash and Oban under fixed names" do
    start_supervised!(
      {AshEnterprise.Telemetry.Metrics,
       vm: false,
       metrics:
         AshEnterprise.Telemetry.Metrics.standard(
           repos: [[:metrics_test, :repo]],
           ash_domains: [AshEnterprise.Telemetry.TestDomain]
         )}
    )

    ms = System.convert_time_unit(1, :millisecond, :native)

    :telemetry.execute([:phoenix, :router_dispatch, :stop], %{duration: 3 * ms}, %{
      route: "/things/:id"
    })

    :telemetry.execute([:phoenix, :live_view, :handle_event, :stop], %{duration: ms}, %{
      socket: %{view: __MODULE__},
      event: "save"
    })

    :telemetry.execute([:metrics_test, :repo, :query], %{total_time: ms, queue_time: ms}, %{
      source: "things"
    })

    :telemetry.execute([:ash, :test_domain, :read, :stop], %{duration: ms}, %{
      resource_short_name: :thing,
      action: %{name: :list}
    })

    :telemetry.execute([:oban, :job, :exception], %{duration: ms}, %{
      job: %{queue: "default", worker: "W"},
      state: :failure
    })

    metrics = collect()

    assert %{%{route: "/things/:id"} => {1, _}} =
             values(metrics, :"phoenix.router_dispatch.stop.duration")

    assert %{%{view: "AshEnterprise.Telemetry.MetricsTest", event: "save"} => {1, _}} =
             values(metrics, :"phoenix.live_view.handle_event.stop.duration")

    assert %{%{repo: "metrics_test.repo", source: "things"} => {1, _}} =
             values(metrics, :"ecto.query.total_time")

    assert %{
             %{domain: "test_domain", resource: "thing", action_type: "read", action: "list"} =>
               {1, _}
           } = values(metrics, :"ash.action.duration")

    assert values(metrics, :"oban.job.exception.count") == %{
             %{queue: "default", worker: "W"} => 1
           }
  end

  test "a metric stops taking new tag sets at max_series" do
    suffix = System.unique_integer([:positive])
    event = [:metrics_test, :"series#{suffix}"]

    start_supervised!(
      {AshEnterprise.Telemetry.Metrics,
       vm: false, max_series: 2, metrics: [counter(event ++ [:n], tags: [:id])]}
    )

    for id <- 1..5, do: :telemetry.execute(event, %{n: 1}, %{id: id})
    :telemetry.execute(event, %{n: 1}, %{id: 1})

    assert values(collect(), :"metrics_test.series#{suffix}.n") == %{
             %{id: 1} => 2,
             %{id: 2} => 1
           }
  end

  test "the reporter detaches its handlers when it stops" do
    event = [:metrics_test, :"detach#{System.unique_integer([:positive])}"]

    start_supervised!(
      {AshEnterprise.Telemetry.Metrics, vm: false, metrics: [counter(event ++ [:n])]}
    )

    assert [_handler] = :telemetry.list_handlers(event)

    stop_supervised!(AshEnterprise.Telemetry.Metrics)
    assert :telemetry.list_handlers(event) == []
  end

  test "the VM metrics report memory, queues, limits and utilisation" do
    start_supervised!(AshEnterprise.Telemetry.VmMetrics)

    first = collect()
    memory = values(first, :"beam.memory")

    assert Map.keys(memory) |> Enum.map(& &1.type) |> Enum.sort() ==
             ~w(atom binary code ets other processes)

    # The parts are read in one call, the total in another: close, not equal.
    [total] = Map.values(values(first, :"beam.memory.total"))
    assert_in_delta Enum.sum(Map.values(memory)), total, total * 0.1

    assert %{%{scheduler: "normal"} => _, %{scheduler: "dirty"} => _} =
             values(first, :"beam.run_queue.length")

    assert [limit] = Map.values(values(first, :"beam.process.limit"))
    assert [count] = Map.values(values(first, :"beam.process.count"))
    assert count > 0 and count < limit
    assert [_] = Map.values(values(first, :"beam.reductions"))

    # Utilisation is a difference of two samples, so it appears from the second export.
    second = collect()
    utilization = values(second, :"beam.scheduler.utilization")
    assert %{type: "total"} in Map.keys(utilization)
    assert Enum.all?(Map.values(utilization), &(&1 >= 0 and &1 <= 1))
  end
end
