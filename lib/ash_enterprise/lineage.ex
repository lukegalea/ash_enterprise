defmodule AshEnterprise.Lineage do
  @moduledoc """
  OpenLineage, kept (ADR 0012, epics E2 and E8): what every write and every
  sync emits, stored here and drawn as a graph by the Lineage app
  (`/app/lineage`).

  The emission machinery lives in `ash_open_lineage`. This domain is the host
  side of it:

    * **Transport.** `AshEnterprise.Lineage.Transport` is every platform
      resource's lineage transport and the `emit/2`/`fail/3` transport. It
      hands each RunEvent to `AshEnterprise.Lineage.Store`, and forwards it
      to an OpenLineage HTTP backend (Marquez) only when
      `config :ash_open_lineage, :http_base_url` is set.
    * **Store.** `AshEnterprise.Lineage.Store` buffers events off the
      caller's path and writes them as three resources: `Job` (one per job
      and tenant), `Run` (one per correlation id: the operation) and
      `JobRun` (one OpenLineage run: one job inside one operation).
      `AshEnterprise.Lineage.Retention` deletes what is older than the
      retention window.
    * **Graph.** `AshEnterprise.Lineage.Graph` derives the job/dataset graph
      for a time window; `AshEnterprise.Lineage.Diagram` draws it for the
      surface's live diagram.
    * **Correlation.** `AshEnterprise.Platform.Correlation` is the
      `AshOpenLineage.CorrelationProvider`. A `Run`'s id is the correlation
      id, which is also the audit log's `correlation_id`, so "the audit
      entries of this run" and "the run of this audit entry" are both a
      lookup, not a join across vocabularies.

  Facets stay structural: `ash_open_lineage` never puts an actor, a tenant or
  a value into an event, and the store keeps the event's names and nothing
  else. The tenant a run belongs to comes from the transport's host metadata
  (`AshOpenLineage.Transport` `send/2`), never from the event.

  ## Who may read it

  The three resources are organization-owned: a read grant on one is
  `:global` inside the reader's tenant, and the tenant filter does the rest.
  Every Administrator holds the read grants (`AshEnterprise.Platform.PrivilegeSync`);
  any other role gets them as ordinary grant rows. Only the store writes
  (as `AshEnterprise.Platform.SystemActor.lineage/0`). Work no tenant owns —
  a correlation that never touched a tenanted row — belongs to the platform
  organization, which nobody signs in to.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Lineage.Job do
      define :list_jobs, action: :read
    end

    resource AshEnterprise.Lineage.Run do
      define :get_run, action: :read, get_by: [:id]
    end

    resource AshEnterprise.Lineage.JobRun do
      define :list_job_runs, action: :read
    end

    resource AshEnterprise.Lineage.Window do
      define :list_windows, action: :read
    end
  end

  @doc """
  Emits an ingestion Job RunEvent (hole rule, ADR 0012: the ingestion step is
  not covered by taps, so the wrapper emits it — nothing rather than a graph
  with a hole where data enters).

      AshEnterprise.Lineage.ingestion_event(:start, "ingestion", "gmail.sync",
        run_id: run_id,
        inputs: ["gmail.source"],
        outputs: [{"ingestion", "ingestion_source_objects"}],
        tenant: organization_id,
        linked_account_id: account_id
      )

  The caller owns the `run_id` (conventionally `AshEnterprise.Platform.Correlation.id()`)
  and passes the same one to `:complete`/`:fail`. The event's correlation id
  is `:correlation_id`, defaulting to the run id.

  `:tenant` and `:linked_account_id` are host metadata for the lineage
  store: they decide whose run this is and which sync it belongs to, and
  never enter the event. Returns `:ok` or `{:error, term}` from the
  transport.
  """
  @spec ingestion_event(:start | :complete | :fail, String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def ingestion_event(event_type, job_namespace, job_name, opts \\ [])

  def ingestion_event(:start, job_namespace, job_name, opts),
    do: AshOpenLineage.emit(job(job_namespace, job_name, opts), emit_opts(:start, opts))

  def ingestion_event(:complete, job_namespace, job_name, opts),
    do: AshOpenLineage.emit(job(job_namespace, job_name, opts), emit_opts(:complete, opts))

  def ingestion_event(:fail, job_namespace, job_name, opts) do
    AshOpenLineage.fail(
      job(job_namespace, job_name, opts),
      Keyword.get(opts, :reason, "unknown"),
      Keyword.delete(emit_opts(:fail, opts), :event_type)
    )
  end

  @doc """
  The run id of job `namespace`/`name` inside the current correlation: the
  same per-(correlation, job) derivation resource jobs get, so a host-emitted
  job that runs inside another job's correlation (a projection inside a sync)
  is its own run rather than sharing the sync's.
  """
  @spec job_run_id(String.t(), String.t(), String.t()) :: String.t()
  def job_run_id(correlation_id, namespace, name),
    do: AshOpenLineage.run_id(correlation_id, namespace, name)

  @doc """
  The OpenLineage dataset a resource writes: the same `namespace`/`name` its
  own COMPLETE events carry (from its `postgres` table), so a host-emitted
  job that names it joins the graph at the same node.
  """
  @spec dataset(module()) :: map() | nil
  def dataset(resource), do: AshOpenLineage.Info.resource_dataset(resource)

  defp job(job_namespace, job_name, opts) do
    %{
      namespace: job_namespace,
      name: job_name,
      inputs: opts[:inputs] || [],
      outputs: opts[:outputs] || []
    }
  end

  defp emit_opts(event_type, opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    meta =
      %{tenant: opts[:tenant], linked_account_id: opts[:linked_account_id]}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    [
      event_type: event_type,
      run_id: run_id,
      correlation_id: Keyword.get(opts, :correlation_id, run_id),
      meta: meta
    ]
  end
end
