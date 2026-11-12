defmodule AshEnterprise.Telemetry.VmMetrics do
  @moduledoc """
  The BEAM's own health as OTLP metrics: memory by type, run queues, process, port,
  atom and ETS counts against their limits, scheduler utilisation, reductions and
  garbage collection.

  Every instrument is observable: the metric reader calls back at each export and
  the value is read then, so nothing polls in between and an idle node costs nothing.
  Started by `AshEnterprise.Telemetry.Metrics` (`vm: true`, the default).

  | Metric | Kind | Unit | Attributes |
  |---|---|---|---|
  | `beam.memory` | gauge | By | `type`: `processes`, `atom`, `binary`, `code`, `ets`, `other` (they sum to the total) |
  | `beam.memory.total` | gauge | By | |
  | `beam.run_queue.length` | gauge | `{process}` | `scheduler`: `normal`, `dirty` |
  | `beam.process.count`, `beam.process.limit` | gauge | `{process}` | |
  | `beam.port.count`, `beam.port.limit` | gauge | `{port}` | |
  | `beam.atom.count`, `beam.atom.limit` | gauge | `{atom}` | |
  | `beam.ets.count`, `beam.ets.limit` | gauge | `{table}` | |
  | `beam.scheduler.utilization` | gauge, 0 to 1, since the previous export | 1 | `type`: `total`, `normal`, `dirty_cpu` |
  | `beam.reductions` | counter (cumulative) | `{reduction}` | |
  | `beam.gc.count` | counter (cumulative) | `{collection}` | |
  | `beam.gc.reclaimed` | counter (cumulative) | By | |

  Scheduler utilisation needs `scheduler_wall_time`, which this process turns on for
  as long as it runs. Its first export after start reports nothing for that metric,
  because utilisation is a difference between two samples.
  """

  use GenServer

  @table :ash_enterprise_telemetry_vm
  @meter_name "ash_enterprise_telemetry"
  @meter_version Mix.Project.config()[:version]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    _previous = :erlang.system_flag(:scheduler_wall_time, true)
    create_instruments(meter())
    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    _previous = :erlang.system_flag(:scheduler_wall_time, false)
    :ok
  end

  # --- Observations: run in the metric reader, so each one is guarded --------------

  @doc false
  def observe(:memory) do
    memory = :erlang.memory()
    total = memory[:total]
    parts = [:processes, :atom, :binary, :code, :ets]
    known = parts |> Enum.map(&memory[&1]) |> Enum.sum()

    Enum.map(parts, &{memory[&1], %{type: Atom.to_string(&1)}}) ++
      [{max(total - known, 0), %{type: "other"}}]
  end

  def observe(:memory_total), do: [{:erlang.memory(:total), %{}}]

  def observe(:run_queue) do
    normal = :erlang.statistics(:total_run_queue_lengths)
    all = :erlang.statistics(:total_run_queue_lengths_all)
    [{normal, %{scheduler: "normal"}}, {max(all - normal, 0), %{scheduler: "dirty"}}]
  end

  def observe({:system_info, key}), do: [{:erlang.system_info(key), %{}}]

  def observe(:reductions) do
    {total, _since_last} = :erlang.statistics(:reductions)
    [{total, %{}}]
  end

  def observe(:gc_count) do
    {count, _words, _zero} = :erlang.statistics(:garbage_collection)
    [{count, %{}}]
  end

  def observe(:gc_reclaimed) do
    {_count, words, _zero} = :erlang.statistics(:garbage_collection)
    [{words * :erlang.system_info(:wordsize), %{}}]
  end

  def observe(:scheduler_utilization) do
    sample = :scheduler.sample_all()

    case :ets.lookup(@table, :scheduler_sample) do
      [{_key, previous}] ->
        :ets.insert(@table, {:scheduler_sample, sample})
        utilization(:scheduler.utilization(previous, sample))

      [] ->
        :ets.insert(@table, {:scheduler_sample, sample})
        []
    end
  end

  @doc false
  def observe_safely(what) do
    observe(what)
  catch
    _kind, _reason -> []
  end

  defp utilization(rows) do
    total = for {:total, value, _percent} <- rows, do: {value, %{type: "total"}}
    total ++ average(rows, :normal, "normal") ++ average(rows, :cpu, "dirty_cpu")
  end

  defp average(rows, kind, label) do
    case for {^kind, _id, value, _percent} <- rows, do: value do
      [] -> []
      values -> [{Enum.sum(values) / length(values), %{type: label}}]
    end
  end

  # --- Instruments -----------------------------------------------------------------

  defp create_instruments(meter) do
    gauge(meter, :"beam.memory", :memory, :By, "Memory allocated by the VM, by type")
    gauge(meter, :"beam.memory.total", :memory_total, :By, "Memory allocated by the VM")

    gauge(
      meter,
      :"beam.run_queue.length",
      :run_queue,
      :"{process}",
      "Processes ready to run, by scheduler kind"
    )

    for {name, key, unit} <- [
          {:"beam.process.count", :process_count, :"{process}"},
          {:"beam.process.limit", :process_limit, :"{process}"},
          {:"beam.port.count", :port_count, :"{port}"},
          {:"beam.port.limit", :port_limit, :"{port}"},
          {:"beam.atom.count", :atom_count, :"{atom}"},
          {:"beam.atom.limit", :atom_limit, :"{atom}"},
          {:"beam.ets.count", :ets_count, :"{table}"},
          {:"beam.ets.limit", :ets_limit, :"{table}"}
        ] do
      gauge(meter, name, {:system_info, key}, unit, nil)
    end

    gauge(
      meter,
      :"beam.scheduler.utilization",
      :scheduler_utilization,
      :"1",
      "Share of wall time schedulers spent busy since the previous export"
    )

    counter(meter, :"beam.reductions", :reductions, :"{reduction}")
    counter(meter, :"beam.gc.count", :gc_count, :"{collection}")
    counter(meter, :"beam.gc.reclaimed", :gc_reclaimed, :By)
  end

  defp gauge(meter, name, what, unit, description) do
    :otel_observable_gauge.create(
      meter,
      name,
      &__MODULE__.observe_safely/1,
      what,
      opts(unit, description)
    )
  end

  defp counter(meter, name, what, unit) do
    :otel_observable_counter.create(
      meter,
      name,
      &__MODULE__.observe_safely/1,
      what,
      opts(unit, nil)
    )
  end

  defp opts(unit, nil), do: %{unit: unit}
  defp opts(unit, description), do: %{unit: unit, description: description}

  # The OTLP encoder reads the meter's scope as a record, so a bare atom name
  # crashes the metric reader on its first export.
  defp meter do
    :opentelemetry_experimental.get_meter(
      :opentelemetry.instrumentation_scope(@meter_name, @meter_version, :undefined)
    )
  end
end
