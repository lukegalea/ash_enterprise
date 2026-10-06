defmodule AshEnterprise.Lineage do
  require Logger

  @moduledoc """
  OpenLineage emission wiring (ADR 0012, epic E2).

  The emission machinery lives in `ash_open_lineage`; this module is the host
  side of two seams:

  **Transport.** `AshOpenLineage.Transport.Req` errors when no endpoint is
  configured, which would log a warning after every write in any deployment
  without Marquez. `AshEnterprise.Lineage.Transport` is the deliberate off
  switch: it forwards to `Req` **only** when
  `config :ash_open_lineage, :http_base_url` is set, and is a silent `:ok`
  otherwise. Lineage is therefore on everywhere, and emits nothing until a
  backend exists — which is exactly the ADR's reversal posture.

  **Correlation.** `AshEnterprise.Platform.Correlation` is registered as the
  `AshOpenLineage.CorrelationProvider`, so the lineage `runId` and the audit
  log's `metadata["correlation_id"]` are the same value and
  "lineage for this audit entry" stays a lookup, not a join. The notifier
  prefers a correlation id stamped into the changeset context by
  `AshEnterprise.Platform.Changes.StampCorrelation` (via `ash_events_metadata`)
  when one is present, falling back to the provider for calls made outside a
  request scope (workers, Oban jobs).
  """

  defmodule Transport do
    @moduledoc """
    Host transport: forward to `AshOpenLineage.Transport.Req` when a backend is
    configured; otherwise drop the event silently.

    Forwarding is asynchronous under the platform's `Task.Supervisor`: a
    notification is not a request the actor waits on, and 440 landed rows must
    not cost 440 sequential HTTP round trips inside a tap run. The
    asynchronicity trades per-event error reporting for write latency — a
    failed POST is logged from the spawned task and otherwise dropped, which is
    the right failure direction for lineage (the audit log, not Marquez, is the
    record of consequence).
    """

    @behaviour AshOpenLineage.Transport

    @impl true
    def send(event) do
      if Application.get_env(:ash_open_lineage, :http_base_url) do
        Task.Supervisor.start_child(AshEnterprise.TaskSupervisor, fn ->
          case AshOpenLineage.Transport.Req.send(event) do
            :ok ->
              :ok

            {:error, error} ->
              Logger.warning("AshOpenLineage: transport dropped event: #{inspect(error)}")
          end
        end)

        :ok
      else
        :ok
      end
    end
  end

  @doc """
  Emits an ingestion Job RunEvent (hole rule, ADR 0012: the ingestion step is
  not covered by taps, so the wrapper emits it — nothing rather than a graph
  with a hole where data enters).

      AshEnterprise.Lineage.ingestion_event(:start, "ingestion", "tap_postgres.app_db",
        run_id: run_id,
        inputs: ["ash_enterprise_dev.public"],
        outputs: [%{namespace: "ingestion", name: "ingestion_source_objects"}]
      )

  The caller owns the `run_id` (conventionally `AshEnterprise.Platform.Correlation.id()`)
  and passes the same one to `:complete`/`:fail`. Returns `:ok` or
  `{:error, term}` from the transport.
  """
  @spec ingestion_event(:start | :complete | :fail, String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def ingestion_event(event_type, job_namespace, job_name, opts \\ [])

  def ingestion_event(:start, job_namespace, job_name, opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    job = %{
      namespace: job_namespace,
      name: job_name,
      inputs: opts[:inputs] || [],
      outputs: opts[:outputs] || []
    }

    AshOpenLineage.emit(job, event_type: :start, run_id: run_id)
  end

  def ingestion_event(:complete, job_namespace, job_name, opts) do
    job = %{
      namespace: job_namespace,
      name: job_name,
      inputs: opts[:inputs] || [],
      outputs: opts[:outputs] || []
    }

    AshOpenLineage.emit(job, event_type: :complete, run_id: Keyword.fetch!(opts, :run_id))
  end

  def ingestion_event(:fail, job_namespace, job_name, opts) do
    job = %{
      namespace: job_namespace,
      name: job_name,
      inputs: opts[:inputs] || [],
      outputs: opts[:outputs] || []
    }

    AshOpenLineage.fail(
      job,
      Keyword.get(opts, :reason, "unknown"),
      run_id: Keyword.fetch!(opts, :run_id)
    )
  end
end
