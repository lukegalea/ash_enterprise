defmodule AshEnterprise.Lineage.Graph do
  @moduledoc """
  The lineage graph for a time window: datasets and jobs as nodes, each job's
  latest run as the edges into and out of it.

      Graph.derive(actor: actor, tenant: tenant, window: "day", job_id: nil)
      #=> {:ok, %{nodes: [...], edges: [...], jobs: [...], runs: [...], since: ~U[...]}}

    * **Nodes.** A job is a node when its latest run falls inside the window;
      a dataset is a node when one of those jobs reads or writes it.
    * **Edges.** `dataset → job` for each input and `job → dataset` for each
      output, carrying the state and time of the job's latest run.
    * **Runs.** The window's running and failed job runs (newest first,
      bounded), plus each job's latest run: what the diagram's markers show.
    * **Filter by job.** With `job_id`, the graph narrows to that job, the
      datasets it touches, and the jobs that read or write those datasets
      (one hop either way). The job is shown even when its latest run is
      older than the window.

  Every read runs as the actor in their tenant, under their grants
  (`AshEnterprise.Lineage.Job`, `JobRun`): an actor without the read grant
  gets an empty graph, and nobody sees another tenant's jobs.
  """

  require Ash.Query

  alias AshEnterprise.Lineage.{Job, JobRun, Window}
  alias AshEnterprise.Security.ActorContext

  @max_jobs 150
  @max_runs 60

  @type graph_node :: %{
          id: String.t(),
          kind: :job | :dataset,
          label: String.t(),
          state: :running | :complete | :failed | nil
        }

  @type edge :: %{from: String.t(), to: String.t(), state: atom(), at: DateTime.t()}

  @type t :: %{
          nodes: [graph_node()],
          edges: [edge()],
          jobs: [Job.t()],
          runs: [JobRun.t()],
          since: DateTime.t()
        }

  @doc """
  Derives the graph. Options: `:actor`, `:tenant`, `:window` (a
  `AshEnterprise.Lineage.Window` id; the last 24 hours by default),
  `:job_id`, `:now`.
  """
  @spec derive(keyword()) :: {:ok, t()} | {:error, term()}
  def derive(opts) do
    since = Window.since(opts[:window], opts[:now] || DateTime.utc_now())

    # Always one tenant: the lineage resources are `global?` multitenant, so
    # a read with no tenant would be every tenant's. No tenant, no graph.
    case opts[:tenant] || ActorContext.tenant(opts[:actor]) do
      nil -> {:ok, build([], [], since)}
      tenant -> derive(since, opts[:job_id], actor: opts[:actor], tenant: tenant)
    end
  end

  defp derive(since, job_id, ash) do
    with {:ok, jobs} <- jobs(since, ash),
         {:ok, jobs} <- focus(jobs, job_id, ash),
         {:ok, runs} <- runs(jobs, since, ash) do
      {:ok, build(jobs, runs, since)}
    end
  end

  @doc "A dataset's display label: `namespace/name`."
  @spec dataset_label(map()) :: String.t()
  def dataset_label(%{"namespace" => namespace, "name" => name}), do: namespace <> "/" <> name
  def dataset_label(%{namespace: namespace, name: name}), do: namespace <> "/" <> name

  @doc "The mermaid node id of a job (`j_…`) or a dataset (`d_…`)."
  @spec node_id(Job.t() | map()) :: String.t()
  def node_id(%Job{namespace: namespace, name: name}), do: "j_" <> short("#{namespace}.#{name}")

  def node_id(%JobRun{job_namespace: namespace, job_name: name}),
    do: "j_" <> short("#{namespace}.#{name}")

  def node_id(dataset) when is_map(dataset), do: "d_" <> short(dataset_label(dataset))

  # --- reads ---------------------------------------------------------------------

  defp jobs(since, ash) do
    Job
    |> Ash.Query.filter(last_run_at >= ^since)
    |> Ash.Query.sort(last_run_at: :desc)
    |> Ash.Query.limit(@max_jobs)
    |> Ash.read(ash)
  end

  defp focus(jobs, nil, _ash), do: {:ok, jobs}

  defp focus(jobs, job_id, ash) do
    case Ash.get(Job, job_id, Keyword.put(ash, :not_found_error?, false)) do
      {:ok, %Job{} = job} ->
        datasets = MapSet.new(job.inputs ++ job.outputs, &dataset_label/1)

        neighbours =
          Enum.filter(jobs, fn other ->
            other.id != job.id and
              Enum.any?(
                other.inputs ++ other.outputs,
                &MapSet.member?(datasets, dataset_label(&1))
              )
          end)

        {:ok, [job | neighbours]}

      {:ok, nil} ->
        {:ok, []}

      {:error, error} ->
        {:error, error}
    end
  end

  defp runs([], _since, _ash), do: {:ok, []}

  defp runs(jobs, since, ash) do
    job_ids = Enum.map(jobs, & &1.id)
    latest_ids = jobs |> Enum.map(& &1.last_job_run_id) |> Enum.reject(&is_nil/1)

    JobRun
    |> Ash.Query.filter(
      job_id in ^job_ids and
        ((last_event_at >= ^since and state in [:running, :failed]) or id in ^latest_ids)
    )
    |> Ash.Query.sort(last_event_at: :desc)
    |> Ash.Query.limit(@max_runs + length(latest_ids))
    |> Ash.read(ash)
  end

  # --- shape ---------------------------------------------------------------------

  defp build(jobs, runs, since) do
    job_nodes =
      Enum.map(jobs, &%{id: node_id(&1), kind: :job, label: &1.label, state: &1.last_state})

    dataset_nodes =
      jobs
      |> Enum.flat_map(&(&1.inputs ++ &1.outputs))
      |> Enum.uniq_by(&dataset_label/1)
      |> Enum.sort_by(&dataset_label/1)
      |> Enum.map(&%{id: node_id(&1), kind: :dataset, label: dataset_label(&1), state: nil})

    edges =
      Enum.flat_map(jobs, fn job ->
        Enum.map(job.inputs, &edge(node_id(&1), node_id(job), job)) ++
          Enum.map(job.outputs, &edge(node_id(job), node_id(&1), job))
      end)
      |> Enum.uniq_by(&{&1.from, &1.to})

    %{nodes: job_nodes ++ dataset_nodes, edges: edges, jobs: jobs, runs: runs, since: since}
  end

  defp edge(from, to, job), do: %{from: from, to: to, state: job.last_state, at: job.last_run_at}

  defp short(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 12)
end
