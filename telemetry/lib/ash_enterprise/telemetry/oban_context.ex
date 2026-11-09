defmodule AshEnterprise.Telemetry.ObanContext do
  @moduledoc """
  Restores the correlation id when an Oban job starts, so the job's span and audit
  rows join the action that enqueued it.

  The start handler is attached before `OpentelemetryOban`, so the consumer span is
  stamped with the restored id. Stop and exception handlers put the previous value
  back: an inline job (`testing: :inline`) and `Oban.drain_queue/2` run in the
  caller's process, and must not leave the job's correlation behind.

  A job with no stamped id (a cron job, or one inserted before this was enabled)
  keeps whatever the process already has, or mints a new one if it has none.

  `attach_job_span/0` replaces `OpentelemetryOban`'s start handler with a guarded one.
  The library's handler calls `DateTime.to_iso8601/1` on `inserted_at` and
  `scheduled_at`, which are `nil` on a job run by `Oban.Engines.Inline`. The raise would
  make `:telemetry` detach the handler for the whole node, ending job spans everywhere.
  """

  alias AshEnterprise.Telemetry.Settings
  alias OpentelemetryOban.JobHandler

  @library_start_handler "Elixir.OpentelemetryOban.JobHandler.job_start"

  @doc "Attaches the start handler. Must run before `OpentelemetryOban.setup/1`."
  @spec attach_before() :: :ok | {:error, :already_exists}
  def attach_before do
    :telemetry.attach(
      {__MODULE__, :start},
      [:oban, :job, :start],
      &__MODULE__.handle_start/4,
      nil
    )
  end

  @doc "Attaches the stop and exception handlers. Must run after `OpentelemetryOban.setup/1`."
  @spec attach_after() :: :ok | {:error, :already_exists}
  def attach_after do
    :telemetry.attach_many(
      {__MODULE__, :stop},
      [[:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_stop/4,
      nil
    )
  end

  @doc "Replaces the library's start handler. Must run after `OpentelemetryOban.setup/1`."
  @spec attach_job_span(atom()) :: :ok | {:error, :already_exists}
  def attach_job_span(span_relationship \\ :link) do
    _ = :telemetry.detach(@library_start_handler)

    :telemetry.attach(
      {__MODULE__, :job_span},
      [:oban, :job, :start],
      &__MODULE__.handle_job_span/4,
      %{span_relationship: span_relationship}
    )
  end

  @doc false
  def handle_job_span(event, measurements, %{job: job} = metadata, config) do
    now = DateTime.utc_now()

    job = %{
      job
      | inserted_at: job.inserted_at || now,
        scheduled_at: job.scheduled_at || now
    }

    JobHandler.handle_job_start(event, measurements, %{metadata | job: job}, config)
    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_job_span(_event, _measurements, _meta, _config), do: :ok

  @doc false
  def handle_start(_event, _measurements, %{job: %{id: id, meta: meta}}, _config) do
    correlation = Settings.correlation()
    previous = correlation.current()

    case meta do
      %{"correlation_id" => stamped} when is_binary(stamped) -> correlation.put(stamped)
      _unstamped -> if is_nil(previous), do: correlation.start_new()
    end

    Process.put({__MODULE__, id}, previous)
    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_start(_event, _measurements, _meta, _config), do: :ok

  @doc false
  def handle_stop(_event, _measurements, %{job: %{id: id}}, _config) do
    correlation = Settings.correlation()

    case Process.delete({__MODULE__, id}) do
      nil -> if function_exported?(correlation, :clear, 0), do: correlation.clear()
      previous -> correlation.put(previous)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_stop(_event, _measurements, _meta, _config), do: :ok
end
