defmodule AshEnterprise.Lineage.Recorder do
  @moduledoc """
  Turns a batch of RunEvents into `Job`, `Run` and `JobRun` rows
  (`AshEnterprise.Lineage.Store` calls it per flush; tests call it inline).

  ## What a row is

    * **JobRun** — one OpenLineage run: one job inside one operation, keyed
      by the event's `run.runId`. Its state is the latest event's
      (`START` running, `COMPLETE` complete, `FAIL` failed); its window runs
      from the first event to the last terminal one. A resource job emits a
      COMPLETE per row written, so a sync that writes 200 messages is one
      job run with an event count of 200, not 200 rows.
    * **Run** — one operation: everything that shared a correlation id. Its
      id *is* the correlation id, which is also the audit log's
      `correlation_id`.
    * **Job** — one job per tenant, with its latest run's state and datasets:
      the graph's nodes.

  Ids are derived, not generated (`derive_id/1`): writing the same events
  twice converges on the same rows, and a batch needs no read-back to link a
  job run to its job.

  ## Whose run it is

  An event's tenant comes from the transport's host metadata, never from the
  event. A correlation belongs to the tenant of its first tenanted event (or
  of its existing run); events in it with no tenant of their own — a landing
  into the untenanted `ingestion_source_objects` during a tenant's sync —
  inherit it. A correlation that never sees a tenant belongs to the platform
  organization, and is dropped when there is none. An event whose own
  tenant differs from its correlation's (a system job sweeping several
  tenants in one process) goes to that tenant's own run under a derived id,
  so no tenant ever sees another's job runs.

  The store is the only writer, so a batch reads what it is about to change
  (three reads), merges in memory and upserts: no counter has to be
  incremented in SQL.
  """

  import Bitwise

  require Ash.Query
  require Logger

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Lineage.{Job, JobRun, Run}
  alias AshEnterprise.Platform.{Seeder, SystemActor}

  @type summary :: %{
          events: non_neg_integer(),
          runs: non_neg_integer(),
          job_runs: non_neg_integer(),
          jobs: non_neg_integer(),
          dropped: non_neg_integer()
        }

  @states %{
    "START" => :running,
    "RUNNING" => :running,
    "COMPLETE" => :complete,
    "FAIL" => :failed
  }
  @max_error 500
  @max_datasets 50

  @doc "The summary of a write that wrote nothing."
  @spec empty_summary() :: summary()
  def empty_summary, do: %{events: 0, runs: 0, job_runs: 0, jobs: 0, dropped: 0}

  @doc "The PubSub topic a tenant's lineage changes are broadcast on."
  @spec topic(String.t()) :: String.t()
  def topic(tenant) when is_binary(tenant), do: "lineage:" <> tenant

  @doc """
  Writes a batch of `{event, meta}` entries, oldest first, and broadcasts
  `{:lineage_recorded, tenant}` on each touched tenant's `topic/1`.
  """
  @spec write([{map(), map()}]) :: summary()
  def write([]), do: empty_summary()

  def write(entries) when is_list(entries) do
    events = entries |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)
    {placed, dropped} = place(events)

    jobs = merge_jobs(placed)
    runs = merge_runs(placed)
    job_runs = merge_job_runs(placed)

    upsert(Job, jobs)
    upsert(Run, runs)
    upsert(JobRun, job_runs)

    placed |> Enum.map(& &1.tenant) |> Enum.uniq() |> Enum.each(&broadcast/1)

    %{
      events: length(entries),
      runs: length(runs),
      job_runs: length(job_runs),
      jobs: length(jobs),
      dropped: dropped + length(entries) - length(events)
    }
  end

  @doc """
  A stable UUID derived from `key`: the first 16 bytes of its SHA-256 with
  the version-8 (custom) and variant bits set.
  """
  @spec derive_id(String.t()) :: Ecto.UUID.t()
  def derive_id(key) when is_binary(key) do
    <<a::binary-size(6), b6, c::binary-size(1), d8, e::binary-size(7), _::binary>> =
      :crypto.hash(:sha256, key)

    {:ok, id} =
      Ecto.UUID.load(a <> <<(b6 &&& 0x0F) ||| 0x80>> <> c <> <<(d8 &&& 0x3F) ||| 0x80>> <> e)

    id
  end

  # --- normalize -----------------------------------------------------------------

  # One event, reduced to what the rows keep: names, ids, times, state and
  # the error message. Anything malformed is dropped rather than guessed at.
  defp normalize(
         {%{
            "eventType" => type,
            "run" => %{"runId" => run_id},
            "job" => %{"namespace" => namespace, "name" => name}
          } = event, meta}
       )
       when is_binary(run_id) and is_map_key(@states, type) and is_binary(namespace) and
              is_binary(name) do
    correlation =
      get_in(event, ["run", "facets", "ashOpenLineageProducer", "correlationId"]) || run_id

    %{
      state: Map.fetch!(@states, type),
      at: event_time(event["eventTime"]),
      run_id: run_id,
      correlation_id: uuid(correlation),
      namespace: namespace,
      name: name,
      inputs: datasets(event["inputs"]),
      outputs: datasets(event["outputs"]),
      error: error_message(event),
      tenant: meta[:tenant],
      linked_account_id: meta[:linked_account_id]
    }
  end

  defp normalize(_malformed), do: nil

  defp event_time(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, at, _offset} -> at
      _unparseable -> DateTime.utc_now()
    end
  end

  defp event_time(_missing), do: DateTime.utc_now()

  defp datasets(list) when is_list(list) do
    for %{"namespace" => namespace, "name" => name} <- list,
        is_binary(namespace) and is_binary(name),
        do: %{"namespace" => namespace, "name" => name}
  end

  defp datasets(_none), do: []

  defp error_message(event) do
    case get_in(event, ["run", "facets", "error", "errorMessage"]) do
      message when is_binary(message) -> String.slice(message, 0, @max_error)
      _none -> nil
    end
  end

  # A correlation id is a UUID everywhere this application makes one; anything
  # else (a host-chosen run id) is mapped onto one deterministically.
  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} when byte_size(value) == 36 -> id
      _not_a_uuid -> derive_id("correlation/" <> value)
    end
  end

  # --- tenancy ---------------------------------------------------------------------

  # Gives every event its tenant and the id of the run it belongs to.
  defp place([]), do: {[], 0}

  defp place(events) do
    correlations = events |> Enum.map(& &1.correlation_id) |> Enum.uniq()
    owners = existing_owners(correlations)

    {placed, dropped, _platform} =
      events
      |> Enum.group_by(& &1.correlation_id)
      |> Enum.reduce({[], 0, :unread}, fn {correlation, group}, {acc, dropped, platform} ->
        group = Enum.sort_by(group, & &1.at, DateTime)

        {owner, platform} =
          case Map.get(owners, correlation) || Enum.find_value(group, & &1.tenant) do
            nil -> platform_tenant(platform)
            tenant -> {tenant, platform}
          end

        case owner do
          nil ->
            {acc, dropped + length(group), platform}

          owner ->
            {Enum.map(group, &assign_run(&1, correlation, owner)) ++ acc, dropped, platform}
        end
      end)

    {placed, dropped}
  end

  defp assign_run(%{tenant: tenant} = event, correlation, owner)
       when is_nil(tenant) or tenant == owner,
       do: %{event | tenant: owner} |> Map.put(:lineage_run_id, correlation)

  defp assign_run(%{tenant: tenant} = event, correlation, _owner),
    do: Map.put(event, :lineage_run_id, derive_id("run/#{correlation}/#{tenant}"))

  # The tenant of each correlation's run already stored (its primary run,
  # whose id is the correlation id).
  defp existing_owners(correlations) do
    Run
    |> Ash.Query.filter(id in ^correlations)
    |> Ash.Query.select([:id, :organization_id])
    |> Ash.read!(actor: SystemActor.lineage())
    |> Map.new(&{&1.id, &1.organization_id})
  end

  defp platform_tenant(:unread) do
    platform =
      Organization
      |> Ash.Query.filter(unique_name == ^Seeder.platform_unique_name())
      |> Ash.Query.select([:id])
      |> Ash.read_one!(authorize?: false)

    tenant = platform && platform.id
    {tenant, tenant}
  end

  defp platform_tenant(tenant), do: {tenant, tenant}

  # --- merge -----------------------------------------------------------------------

  defp merge_job_runs(events) do
    groups = Enum.group_by(events, &{&1.tenant, &1.run_id})

    ids =
      Map.new(groups, fn {{tenant, run_id}, _} ->
        {{tenant, run_id}, job_run_id(tenant, run_id)}
      end)

    existing = existing(JobRun, Map.values(ids))

    Enum.map(groups, fn {{tenant, run_id} = key, group} ->
      id = Map.fetch!(ids, key)
      merge_job_run(id, tenant, run_id, sorted(group), Map.get(existing, id, %{}))
    end)
  end

  # `old` is the stored row, or `%{}` for a new one.
  defp merge_job_run(id, tenant, run_id, group, old) do
    last = List.last(group)

    %{
      id: id,
      tenant: tenant,
      run_id: run_id,
      lineage_run_id: last.lineage_run_id,
      job_id: job_id(tenant, last.namespace, last.name),
      job_namespace: last.namespace,
      job_name: last.name,
      state: last.state,
      started_at: earliest([old[:started_at], hd(group).at]),
      ended_at: ended_at(last, old),
      last_event_at: latest([old[:last_event_at], last.at]),
      event_count: (old[:event_count] || 0) + length(group),
      inputs: union(old[:inputs], Enum.flat_map(group, & &1.inputs)),
      outputs: union(old[:outputs], Enum.flat_map(group, & &1.outputs)),
      error_message: error_after(last, group, old)
    }
  end

  defp ended_at(%{state: :running}, _old), do: nil
  defp ended_at(last, old), do: latest([old[:ended_at], last.at])

  defp error_after(%{state: :failed}, group, old),
    do: Enum.find_value(Enum.reverse(group), & &1.error) || old[:error_message]

  defp error_after(_last, _group, _old), do: nil

  defp merge_runs(events) do
    groups = Enum.group_by(events, &{&1.tenant, &1.lineage_run_id})
    existing = existing(Run, Enum.map(Map.keys(groups), &elem(&1, 1)))

    Enum.map(groups, fn {{tenant, id}, group} ->
      merge_run(id, tenant, sorted(group), Map.get(existing, id, %{}))
    end)
  end

  defp merge_run(id, tenant, group, old) do
    root = Enum.find(group, &(&1.state == :running)) || hd(group)

    %{
      id: id,
      tenant: tenant,
      correlation_id: hd(group).correlation_id,
      job_id: old[:job_id] || job_id(tenant, root.namespace, root.name),
      job_label: old[:job_label] || label(root),
      linked_account_id:
        old[:linked_account_id] || Enum.find_value(group, & &1.linked_account_id),
      first_event_at: earliest([old[:first_event_at], hd(group).at]),
      last_event_at: latest([old[:last_event_at], List.last(group).at])
    }
  end

  defp sorted(group), do: Enum.sort_by(group, & &1.at, DateTime)

  defp merge_jobs(events) do
    groups = Enum.group_by(events, &{&1.tenant, &1.namespace, &1.name})

    ids =
      Map.new(groups, fn {{tenant, namespace, name} = key, _} ->
        {key, job_id(tenant, namespace, name)}
      end)

    existing = existing(Job, Map.values(ids))
    known_runs = existing_job_run_ids(events)

    Enum.map(groups, fn {{tenant, namespace, name} = key, group} ->
      group = Enum.sort_by(group, & &1.at, DateTime)
      id = Map.fetch!(ids, key)
      old = Map.get(existing, id)
      last = List.last(group)

      new_runs =
        group
        |> Enum.map(&job_run_id(&1.tenant, &1.run_id))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(known_runs, &1))
        |> length()

      newer? =
        is_nil(old) or is_nil(old.last_run_at) or
          DateTime.compare(last.at, old.last_run_at) != :lt

      base = %{
        id: id,
        tenant: tenant,
        namespace: namespace,
        name: name,
        label: Job.label_for(namespace, name),
        run_count: ((old && old.run_count) || 0) + new_runs,
        inputs: union(old && old.inputs, Enum.flat_map(group, & &1.inputs)),
        outputs: union(old && old.outputs, Enum.flat_map(group, & &1.outputs))
      }

      if newer? do
        Map.merge(base, %{
          last_state: last.state,
          last_run_at: last.at,
          last_job_run_id: job_run_id(tenant, last.run_id),
          last_lineage_run_id: last.lineage_run_id,
          last_error: if(last.state == :failed, do: last.error)
        })
      else
        Map.merge(
          base,
          Map.take(old, [
            :last_state,
            :last_run_at,
            :last_job_run_id,
            :last_lineage_run_id,
            :last_error
          ])
        )
      end
    end)
  end

  defp existing(_resource, []), do: %{}

  defp existing(resource, ids) do
    resource
    |> Ash.Query.filter(id in ^Enum.uniq(ids))
    |> Ash.read!(actor: SystemActor.lineage())
    |> Map.new(&{&1.id, Map.from_struct(&1)})
  end

  defp existing_job_run_ids(events) do
    ids = events |> Enum.map(&job_run_id(&1.tenant, &1.run_id)) |> Enum.uniq()

    JobRun
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id])
    |> Ash.read!(actor: SystemActor.lineage())
    |> MapSet.new(& &1.id)
  end

  # --- write -------------------------------------------------------------------------

  defp upsert(_resource, []), do: :ok

  defp upsert(resource, rows) do
    rows
    |> Enum.group_by(& &1.tenant, &Map.delete(&1, :tenant))
    |> Enum.each(fn {tenant, inputs} ->
      result =
        Ash.bulk_create(inputs, resource, :record,
          tenant: tenant,
          actor: SystemActor.lineage(),
          return_errors?: true,
          stop_on_error?: false
        )

      if result.error_count > 0 do
        Logger.warning(
          "AshEnterprise.Lineage: #{result.error_count} #{inspect(resource)} rows not written: " <>
            Enum.map_join(result.errors || [], "; ", &error_class/1)
        )
      end
    end)
  end

  defp error_class(%{__struct__: module}), do: inspect(module)
  defp error_class(other), do: inspect(other)

  defp broadcast(tenant),
    do: Phoenix.PubSub.broadcast(AshEnterprise.PubSub, topic(tenant), {:lineage_recorded, tenant})

  # --- helpers -----------------------------------------------------------------------

  defp job_id(tenant, namespace, name), do: derive_id("job/#{tenant}/#{namespace}/#{name}")
  defp job_run_id(tenant, run_id), do: derive_id("job_run/#{tenant}/#{run_id}")

  defp label(%{namespace: namespace, name: name}), do: Job.label_for(namespace, name)

  defp union(old, new) do
    (List.wrap(old) ++ new)
    |> Enum.uniq_by(&{&1["namespace"], &1["name"]})
    |> Enum.take(@max_datasets)
  end

  defp earliest(times),
    do: times |> Enum.reject(&is_nil/1) |> Enum.min(DateTime, fn -> nil end)

  defp latest(times),
    do: times |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)
end
