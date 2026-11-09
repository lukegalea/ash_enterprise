defmodule AshEnterprise.Telemetry.BackgroundProbe do
  @moduledoc """
  Metrics for background work that has no user waiting on it: stuck queues,
  silently failing cron, discarded jobs and Lifeline rescues.

      config :ash_enterprise_telemetry, :background_probe,
        repo: MyApp.Repo,
        period: 15_000

  A `telemetry_poller` measurement reads `oban_jobs` every period, and this process
  owns the ETS table the observable gauges read from.

  Labels are bounded to queue and state, or worker for cron. Job ids, arguments and
  tenants are never labels. New series beyond `:max_series` (default 1000) are dropped.

  | Metric | Kind | Labels |
  |---|---|---|
  | `oban.queue.depth` | observable gauge | `queue`, `state` |
  | `oban.queue.age` | observable gauge, seconds since the oldest job became due | `queue`, `state` |
  | `oban.cron.last_success_age` | observable gauge, seconds | `worker` |
  | `oban.job.discards` | counter (delta) | `queue` |
  | `oban.lifeline.rescues` | counter (delta) | `outcome` (`rescued`, `discarded`) |

  The SDK reports sync counters as delta and observable gauges as cumulative, so
  one process emits mixed temporality.

  A series seen once keeps reporting, as zero when its count has gone, so a queue that
  empties does not vanish from a chart.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias Oban.Job

  require Logger

  @table :ash_enterprise_telemetry_probe
  @tracked_states ~w(available scheduled executing retryable)
  @default_period 15_000
  @default_max_series 1_000
  @handler_id {__MODULE__, :events}

  @meter_name "ash_enterprise_telemetry"
  @meter_version Mix.Project.config()[:version]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs one measurement. Called by `telemetry_poller`, and by tests. Never raises:
  a query failure leaves the previous values in place.
  """
  @spec poll(keyword()) :: :ok
  def poll(opts) do
    repo = Keyword.fetch!(opts, :repo)
    now = DateTime.utc_now()

    rows =
      repo.all(
        from(j in Job,
          where: j.state in @tracked_states,
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id), min(j.scheduled_at)}
        ),
        Keyword.take(opts, [:prefix])
      )

    record_queues(rows, now, opts)
    record_cron_from_db(repo, opts)
    :ok
  rescue
    exception ->
      Logger.debug("BackgroundProbe poll failed: " <> Exception.message(exception))
      :ok
  catch
    _kind, _reason -> :ok
  end

  # --- Recording ------------------------------------------------------------------

  defp record_queues(rows, now, opts) do
    seen =
      Map.new(rows, fn {queue, state, count, oldest} ->
        {{queue, state}, {count, age_seconds(oldest, now)}}
      end)

    known = for [series] <- :ets.match(@table, {{:series, :"$1"}, :_}), do: series

    for series <- Enum.uniq(known ++ Map.keys(seen)) do
      if series in known or series_room?(opts) do
        {count, age} = Map.get(seen, series, {0, 0})
        :ets.insert(@table, {{:series, series}, {count, age}})
        emit(series, count, age)
      end
    end
  end

  defp series_room?(opts) do
    :ets.info(@table, :size) < Keyword.get(opts, :max_series, @default_max_series)
  end

  defp emit({queue, state}, count, age) do
    :telemetry.execute(
      [:ash_enterprise_telemetry, :oban, :queue],
      %{depth: count, age: age},
      %{queue: queue, state: state}
    )
  end

  defp age_seconds(nil, _now), do: 0

  defp age_seconds(%NaiveDateTime{} = oldest, now) do
    oldest |> DateTime.from_naive!("Etc/UTC") |> age_seconds(now)
  end

  defp age_seconds(%DateTime{} = oldest, now), do: max(DateTime.diff(now, oldest, :second), 0)

  # Fills the gap after a restart, when no success has been observed in this VM yet.
  defp record_cron_from_db(repo, opts) do
    rows =
      repo.all(
        from(j in Job,
          where:
            j.state == "completed" and
              fragment("?->>'cron' = 'true'", j.meta),
          group_by: j.worker,
          select: {j.worker, max(j.completed_at)}
        ),
        Keyword.take(opts, [:prefix])
      )

    for {worker, completed_at} <- rows, not is_nil(completed_at) do
      unix = DateTime.to_unix(completed_at, :second)

      case :ets.lookup(@table, {:cron, worker}) do
        [{_key, recorded}] when recorded >= unix -> :ok
        _older_or_none -> if series_room?(opts), do: :ets.insert(@table, {{:cron, worker}, unix})
      end
    end
  end

  # --- Observable callbacks: run in the metric reader ------------------------------

  @doc false
  def observe_depth(_args) do
    for [{queue, state}, {count, _age}] <- :ets.match(@table, {{:series, :"$1"}, :"$2"}) do
      {count, %{queue: queue, state: state}}
    end
  end

  @doc false
  def observe_age(_args) do
    for [{queue, state}, {_count, age}] <- :ets.match(@table, {{:series, :"$1"}, :"$2"}) do
      {age, %{queue: queue, state: state}}
    end
  end

  @doc false
  def observe_cron(_args) do
    now = System.system_time(:second)

    for [worker, unix] <- :ets.match(@table, {{:cron, :"$1"}, :"$2"}) do
      {max(now - unix, 0), %{worker: worker}}
    end
  end

  # --- Telemetry handlers ---------------------------------------------------------

  @doc false
  def handle_event(
        [:oban, :job, _end],
        _measurements,
        %{job: %{queue: _} = job, state: state},
        _config
      ) do
    meter = meter()

    if state == :discard do
      add(meter, :"oban.job.discards", 1, %{queue: job.queue})
    end

    if state == :success and match?(%{"cron" => true}, job.meta) do
      :ets.insert(@table, {{:cron, job.worker}, System.system_time(:second)})
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_event(
        [:oban, :plugin, :stop],
        _measurements,
        %{plugin: Oban.Plugins.Lifeline} = meta,
        _config
      ) do
    meter = meter()

    if rescued = counted(meta[:rescued_jobs]) do
      add(meter, :"oban.lifeline.rescues", rescued, %{outcome: "rescued"})
    end

    if discarded = counted(meta[:discarded_jobs]) do
      add(meter, :"oban.lifeline.rescues", discarded, %{outcome: "discarded"})
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  defp counted(jobs) when is_list(jobs) and jobs != [], do: length(jobs)
  defp counted(_none), do: nil

  defp add(meter, name, value, attributes) do
    :otel_counter.add(OpenTelemetry.Ctx.get_current(), meter, name, value, attributes)
  end

  # The OTLP encoder reads the meter's scope as a record, so a bare atom name
  # crashes the metric reader on its first export.
  defp meter do
    :opentelemetry_experimental.get_meter(
      :opentelemetry.instrumentation_scope(@meter_name, @meter_version, :undefined)
    )
  end

  # --- GenServer ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    create_instruments()

    :telemetry.attach_many(
      @handler_id,
      [[:oban, :job, :stop], [:oban, :job, :exception], [:oban, :plugin, :stop]],
      &__MODULE__.handle_event/4,
      nil
    )

    poller = start_poller(opts)
    {:ok, %{poller: poller}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
  end

  defp create_instruments do
    meter = meter()

    :otel_counter.create(meter, :"oban.job.discards", %{unit: :"{job}"})
    :otel_counter.create(meter, :"oban.lifeline.rescues", %{unit: :"{job}"})

    :otel_observable_gauge.create(meter, :"oban.queue.depth", &__MODULE__.observe_depth/1, [], %{
      unit: :"{job}"
    })

    :otel_observable_gauge.create(meter, :"oban.queue.age", &__MODULE__.observe_age/1, [], %{
      unit: :s
    })

    :otel_observable_gauge.create(
      meter,
      :"oban.cron.last_success_age",
      &__MODULE__.observe_cron/1,
      [],
      %{unit: :s}
    )
  end

  defp start_poller(opts) do
    period = Keyword.get(opts, :period, @default_period)

    {:ok, pid} =
      :telemetry_poller.start_link(
        measurements: [{__MODULE__, :poll, [opts]}],
        period: period,
        init_delay: Keyword.get(opts, :init_delay, period),
        name: Module.concat(__MODULE__, Poller)
      )

    pid
  end
end
