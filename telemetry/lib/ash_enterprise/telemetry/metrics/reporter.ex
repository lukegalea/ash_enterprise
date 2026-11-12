defmodule AshEnterprise.Telemetry.Metrics.Reporter do
  @moduledoc """
  Attaches a handler per event and records each metric on its instrument. Started by
  `AshEnterprise.Telemetry.Metrics`, which documents the mapping.
  """

  use GenServer

  require Logger

  @meter_name "ash_enterprise_telemetry"
  @meter_version Mix.Project.config()[:version]
  @default_max_series 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    table = :ets.new(__MODULE__, [:public, :set, write_concurrency: true])
    meter = meter()
    max_series = Keyword.get(opts, :max_series, @default_max_series)

    metrics =
      opts
      |> Keyword.get(:metrics, [])
      |> Enum.flat_map(&prepare(&1, meter, table))

    handler_ids =
      metrics
      |> Enum.group_by(& &1.metric.event_name)
      |> Enum.map(fn {event, group} ->
        id = {__MODULE__, event, self()}

        :ok =
          :telemetry.attach(id, event, &__MODULE__.handle_telemetry/4, %{
            metrics: group,
            meter: meter,
            table: table,
            max_series: max_series
          })

        id
      end)

    {:ok, %{handler_ids: handler_ids}}
  end

  @impl GenServer
  def terminate(_reason, %{handler_ids: handler_ids}) do
    Enum.each(handler_ids, &:telemetry.detach/1)
  end

  # --- Instruments -------------------------------------------------------------------

  defp prepare(metric, meter, table) do
    name = instrument_name(metric)
    opts = instrument_opts(metric)

    # One instrument per name: `standard/1` defines `ash.action.duration` once per
    # domain and action type, all recording into the same histogram.
    if :ets.insert_new(table, {{:instrument, name}}), do: create(metric, name, opts, meter, table)

    [%{metric: metric, name: name, kind: kind(metric)}]
  rescue
    exception ->
      Logger.warning(
        "AshEnterprise.Telemetry.Metrics skipped a metric: " <> Exception.message(exception)
      )

      []
  end

  defp create(metric, name, opts, meter, table) do
    case kind(metric) do
      :counter ->
        :otel_counter.create(meter, name, opts)

      :sum ->
        :otel_updown_counter.create(meter, name, opts)

      :histogram ->
        :otel_histogram.create(meter, name, histogram_opts(metric, opts))

      :last_value ->
        :otel_observable_gauge.create(
          meter,
          name,
          &__MODULE__.observe_last_value/1,
          {table, name},
          opts
        )
    end
  end

  defp kind(%Telemetry.Metrics.Counter{}), do: :counter
  defp kind(%Telemetry.Metrics.Sum{}), do: :sum
  defp kind(%Telemetry.Metrics.LastValue{}), do: :last_value
  defp kind(%Telemetry.Metrics.Summary{}), do: :histogram
  defp kind(%Telemetry.Metrics.Distribution{}), do: :histogram

  # Metric names come from the host's own definitions, a fixed set known at boot.
  defp instrument_name(metric) do
    metric.name |> Enum.map_join(".", &Atom.to_string/1) |> String.to_atom()
  end

  defp instrument_opts(metric) do
    case metric.description do
      nil -> %{unit: otel_unit(metric.unit)}
      description -> %{unit: otel_unit(metric.unit), description: description}
    end
  end

  defp histogram_opts(metric, opts) do
    case Keyword.get(metric.reporter_options, :buckets) do
      [_ | _] = buckets -> Map.put(opts, :advisory_params, %{explicit_bucket_boundaries: buckets})
      _none -> opts
    end
  end

  @units %{
    nanosecond: :ns,
    microsecond: :us,
    millisecond: :ms,
    second: :s,
    byte: :By,
    kilobyte: :kBy,
    megabyte: :MBy
  }

  defp otel_unit(unit), do: Map.get(@units, unit, :"1")

  # --- Events ------------------------------------------------------------------------

  @doc false
  def handle_telemetry(_event, measurements, metadata, config) do
    for entry <- config.metrics do
      record(entry, measurements, metadata, config)
    end

    :ok
  end

  defp record(%{metric: metric, name: name, kind: kind}, measurements, metadata, config) do
    with true <- keep?(metric, metadata),
         value when is_number(value) <- measurement(kind, metric, measurements, metadata),
         attributes = attributes(metric, metadata),
         true <- room?(config, name, attributes) do
      ctx = OpenTelemetry.Ctx.get_current()

      case kind do
        :counter -> :otel_counter.add(ctx, config.meter, name, 1, attributes)
        :sum -> :otel_updown_counter.add(ctx, config.meter, name, value, attributes)
        :histogram -> :otel_histogram.record(ctx, config.meter, name, value, attributes)
        :last_value -> :ets.insert(config.table, {{:value, name, attributes}, value})
      end
    end
  catch
    _kind, _reason -> :ok
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(%{keep: keep}, metadata), do: keep.(metadata)

  # A counter counts events; it has no measurement to read.
  defp measurement(:counter, _metric, _measurements, _metadata), do: 1

  defp measurement(_kind, metric, measurements, metadata),
    do: measurement(metric, measurements, metadata)

  defp measurement(%{measurement: fun}, measurements, _metadata) when is_function(fun, 1),
    do: fun.(measurements)

  defp measurement(%{measurement: fun}, measurements, metadata) when is_function(fun, 2),
    do: fun.(measurements, metadata)

  defp measurement(%{measurement: key}, measurements, _metadata), do: measurements[key]

  defp attributes(metric, metadata) do
    metadata
    |> metric.tag_values.()
    |> Map.take(metric.tags)
    |> Map.new(fn {key, value} -> {key, attribute_value(value)} end)
  end

  defp attribute_value(value) when is_binary(value), do: value
  defp attribute_value(value) when is_number(value) or is_boolean(value), do: value
  defp attribute_value(nil), do: ""

  defp attribute_value(value) when is_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> module -> module
      other -> other
    end
  end

  defp attribute_value(value), do: inspect(value, limit: 5, printable_limit: 64)

  # A new tag set is admitted while the metric is under its limit; a known one always is.
  defp room?(config, name, attributes) do
    key = {:series, name, attributes}

    cond do
      :ets.member(config.table, key) ->
        true

      :ets.update_counter(config.table, {:count, name}, 1, {{:count, name}, 0}) <=
          config.max_series ->
        :ets.insert(config.table, {key})
        true

      true ->
        false
    end
  end

  @doc false
  def observe_last_value({table, name}) do
    for [attributes, value] <- :ets.match(table, {{:value, name, :"$1"}, :"$2"}) do
      {value, attributes}
    end
  catch
    _kind, _reason -> []
  end

  defp meter do
    :opentelemetry_experimental.get_meter(
      :opentelemetry.instrumentation_scope(@meter_name, @meter_version, :undefined)
    )
  end
end
