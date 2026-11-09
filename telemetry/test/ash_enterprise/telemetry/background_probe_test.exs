defmodule AshEnterprise.Telemetry.BackgroundProbeTest do
  # The probe is a named singleton with a named ETS table.
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.BackgroundProbe
  alias AshEnterprise.Telemetry.TestRepo
  alias Oban.Job

  require Record

  Record.defrecordp(
    :metric,
    Record.extract(:metric, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :sum,
    Record.extract(:sum, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :gauge,
    Record.extract(:gauge, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :datapoint,
    Record.extract(:datapoint, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  @opts [repo: TestRepo, period: 3_600_000, init_delay: 3_600_000]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(TestRepo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    start_supervised!({BackgroundProbe, @opts})
    Process.register(self(), :ash_telemetry_test_metrics)
    :ok
  end

  defp insert_job(attrs) do
    now = DateTime.utc_now()

    defaults = %{
      worker: "Test.Worker",
      queue: "probe_q",
      state: "available",
      args: %{},
      meta: %{},
      scheduled_at: now,
      inserted_at: now,
      attempted_at: nil,
      completed_at: nil
    }

    TestRepo.insert!(struct!(Job, Map.merge(defaults, Map.new(attrs))))
  end

  defp collect do
    :otel_meter_server.force_flush()
    drain(%{})
  end

  defp drain(acc) do
    receive do
      {:otel_metric, record} -> drain(Map.put(acc, metric(record, :name), metric(record, :data)))
    after
      100 -> acc
    end
  end

  defp records do
    :otel_meter_server.force_flush()
    drain_records([])
  end

  defp drain_records(acc) do
    receive do
      {:otel_metric, record} -> drain_records([record | acc])
    after
      100 -> acc
    end
  end

  defp points(data) when Record.is_record(data, :sum), do: sum(data, :datapoints)
  defp points(data) when Record.is_record(data, :gauge), do: gauge(data, :datapoints)

  defp values(metrics, name) do
    metrics
    |> Map.fetch!(name)
    |> points()
    |> Map.new(fn point ->
      {datapoint(point, :attributes), datapoint(point, :value)}
    end)
  end

  defp job_event(event, measurements \\ %{duration: 1}, meta) do
    :telemetry.execute([:oban, :job, event], measurements, meta)
  end

  test "queue depth and age are reported per queue and state" do
    insert_job(state: "available")
    insert_job(state: "available")
    insert_job(state: "scheduled", scheduled_at: DateTime.add(DateTime.utc_now(), 3_600))
    insert_job(state: "completed", completed_at: DateTime.utc_now())

    assert BackgroundProbe.poll(@opts) == :ok

    metrics = collect()
    depth = values(metrics, :"oban.queue.depth")

    assert depth[%{queue: "probe_q", state: "available"}] == 2
    assert depth[%{queue: "probe_q", state: "scheduled"}] == 1
    refute Map.has_key?(depth, %{queue: "probe_q", state: "completed"})

    assert Map.has_key?(values(metrics, :"oban.queue.age"), %{
             queue: "probe_q",
             state: "available"
           })
  end

  test "an old job shows a positive age" do
    insert_job(state: "available", scheduled_at: DateTime.add(DateTime.utc_now(), -120))

    BackgroundProbe.poll(@opts)

    assert values(collect(), :"oban.queue.age")[%{queue: "probe_q", state: "available"}] >= 119
  end

  test "a queue that empties reports zero rather than disappearing" do
    job = insert_job(state: "available")
    BackgroundProbe.poll(@opts)
    collect()

    TestRepo.delete!(job)
    BackgroundProbe.poll(@opts)

    assert values(collect(), :"oban.queue.depth")[%{queue: "probe_q", state: "available"}] == 0
  end

  test "series are bounded: beyond max_series, new queues are dropped" do
    insert_job(queue: "first_q")
    BackgroundProbe.poll(@opts)
    collect()

    insert_job(queue: "second_q")
    BackgroundProbe.poll(@opts ++ [max_series: 1])

    depth = values(collect(), :"oban.queue.depth")
    assert Map.has_key?(depth, %{queue: "first_q", state: "available"})
    refute Map.has_key?(depth, %{queue: "second_q", state: "available"})
  end

  test "a failing query leaves the probe alive and returns :ok" do
    assert BackgroundProbe.poll(repo: NoSuchRepo) == :ok
    assert Process.whereis(BackgroundProbe)
  end

  test "cron last-success age comes from a job's stop event" do
    job = %Job{id: 1, queue: "q", worker: "Cron.Worker", meta: %{"cron" => true}}
    job_event(:stop, %{job: job, state: :success})

    assert values(collect(), :"oban.cron.last_success_age")[%{worker: "Cron.Worker"}] <= 1
  end

  test "cron is seeded from the database after a restart" do
    insert_job(
      worker: "Seeded.Worker",
      state: "completed",
      meta: %{"cron" => true},
      completed_at: DateTime.add(DateTime.utc_now(), -300)
    )

    BackgroundProbe.poll(@opts)

    assert values(collect(), :"oban.cron.last_success_age")[%{worker: "Seeded.Worker"}] >= 299
  end

  test "a non-cron success records nothing" do
    job_event(:stop, %{
      job: %Job{id: 2, queue: "q", worker: "Plain.Worker", meta: %{}},
      state: :success
    })

    metrics = collect()

    refute Map.has_key?(
             (metrics[:"oban.cron.last_success_age"] &&
                values(metrics, :"oban.cron.last_success_age")) || %{},
             %{worker: "Plain.Worker"}
           )
  end

  test "both a delta counter and an observable gauge are emitted" do
    job_event(:stop, %{job: %Job{id: 3, queue: "disc_q", worker: "W", meta: %{}}, state: :discard})

    job_event(:stop, %{job: %Job{id: 4, queue: "disc_q", worker: "W", meta: %{}}, state: :discard})

    insert_job(queue: "gauge_q")
    BackgroundProbe.poll(@opts)

    metrics = collect()

    discards = Map.fetch!(metrics, :"oban.job.discards")
    assert sum(discards, :aggregation_temporality) == :temporality_delta
    assert sum(discards, :is_monotonic) == true
    assert values(metrics, :"oban.job.discards")[%{queue: "disc_q"}] == 2

    depth = Map.fetch!(metrics, :"oban.queue.depth")
    assert Record.is_record(depth, :gauge)
  end

  test "the collected metrics encode as OTLP" do
    # The encoder is stricter than the in-VM reader: a meter with a bare atom scope
    # collects fine and only crashes when it reaches OTLP.
    job_event(:stop, %{job: %Job{id: 6, queue: "enc_q", worker: "W", meta: %{}}, state: :discard})
    insert_job(queue: "enc_gauge_q")
    BackgroundProbe.poll(@opts)

    assert %{resource_metrics: [%{scope_metrics: [_ | _]}]} =
             :otel_otlp_metrics.to_proto(records(), :otel_resource.create(%{}))
  end

  test "the delta counter does not repeat across collections" do
    job_event(:stop, %{job: %Job{id: 5, queue: "once_q", worker: "W", meta: %{}}, state: :discard})

    first = collect()
    second = collect()

    assert values(first, :"oban.job.discards")[%{queue: "once_q"}] == 1

    assert (second[:"oban.job.discards"] &&
              values(second, :"oban.job.discards")[%{queue: "once_q"}]) in [nil, 0]
  end

  test "Lifeline rescues are counted by outcome" do
    :telemetry.execute(
      [:oban, :plugin, :stop],
      %{duration: 1},
      %{plugin: Oban.Plugins.Lifeline, rescued_jobs: [%Job{}, %Job{}], discarded_jobs: [%Job{}]}
    )

    rescues = values(collect(), :"oban.lifeline.rescues")
    assert rescues[%{outcome: "rescued"}] == 2
    assert rescues[%{outcome: "discarded"}] == 1
  end

  test "other plugins are ignored, and malformed events do not detach the handler" do
    :telemetry.execute([:oban, :plugin, :stop], %{}, %{plugin: Oban.Plugins.Cron})
    :telemetry.execute([:oban, :job, :stop], %{}, %{job: :garbage, state: :discard})
    :telemetry.execute([:oban, :job, :stop], %{}, %{})

    assert Enum.any?(
             :telemetry.list_handlers([:oban, :job, :stop]),
             &(&1.id == {BackgroundProbe, :events})
           )
  end
end
