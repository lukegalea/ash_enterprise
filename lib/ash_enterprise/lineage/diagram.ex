defmodule AshEnterprise.Lineage.Diagram do
  @moduledoc """
  The Lineage surface's live diagram (`AshA2ui.Diagram.Source`): the graph
  `AshEnterprise.Lineage.Graph` derives, as a mermaid flowchart, with one
  marker per run worth seeing.

    * Datasets are cylinders, jobs are rounded boxes; edges run from what a
      job reads to the job, and from the job to what it writes.
    * Markers sit on job nodes: a **failed** run (the danger fill — red), a
      **running** one (pulsing), and each job's latest run when it completed
      (muted). Each opens its run (`{AshEnterprise.Lineage.Run, id}`, resolved
      to the Lineage surface's run detail on the server).

  State is carried by the markers, never by the drawn source: the source is
  drawn once per surface build, while the markers move on every refresh. So
  a run that fails while the page is open turns its job's marker red without
  redrawing anything.

  The surface's `window` and `job` contexts narrow the graph. The source
  reads them on every build; `AshEnterpriseWeb.LineageLive` rebuilds the
  surface when either changes, which is what redraws it.
  """

  @behaviour AshA2ui.Diagram.Source

  alias AshEnterprise.Lineage.{Graph, JobRun}
  alias AshEnterprise.Platform.LocalTime

  @empty "flowchart LR\n  empty([\"No runs in this window\"])"

  @impl true
  def diagram(context) do
    contexts = Map.get(context, :contexts, %{})

    opts = [
      actor: context.actor,
      tenant: context.tenant,
      window: contexts[:window],
      job_id: contexts[:job]
    ]

    case Graph.derive(opts) do
      {:ok, graph} -> {:ok, render(graph)}
      {:error, _error} -> {:error, :unreadable}
    end
  end

  @doc "The diagram for a derived graph: `%{source: mermaid, markers: [...]}`."
  @spec render(Graph.t()) :: %{source: String.t(), markers: [map()]}
  def render(%{nodes: []}), do: %{source: @empty, markers: []}

  def render(graph) do
    %{source: mermaid(graph), markers: markers(graph)}
  end

  @doc "The mermaid source alone: what `LineageLive` compares to tell whether to redraw."
  @spec mermaid(Graph.t()) :: String.t()
  def mermaid(%{nodes: []}), do: @empty

  def mermaid(graph) do
    nodes = Enum.map(graph.nodes, &node_line/1)
    edges = Enum.map(graph.edges, &"  #{&1.from} --> #{&1.to}")

    Enum.join(["flowchart LR" | nodes ++ edges], "\n")
  end

  defp node_line(%{kind: :dataset, id: id, label: label}), do: ~s|  #{id}[("#{escape(label)}")]|
  defp node_line(%{kind: :job, id: id, label: label}), do: ~s|  #{id}("#{escape(label)}")|

  # Quoted mermaid labels end at a double quote; nothing else in a job or
  # table name needs escaping inside one.
  defp escape(label), do: String.replace(label, ~s("), "'")

  # --- markers -------------------------------------------------------------------

  defp markers(graph) do
    shown = graph.runs |> Enum.filter(&(&1.state in [:running, :failed])) |> Enum.map(& &1.id)
    shown_set = MapSet.new(shown)
    by_id = Map.new(graph.runs, &{&1.id, &1})

    problem_markers =
      graph.runs
      |> Enum.filter(&MapSet.member?(shown_set, &1.id))
      |> Enum.map(&marker/1)

    latest_markers =
      graph.jobs
      |> Enum.map(&Map.get(by_id, &1.last_job_run_id))
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(shown_set, &1.id)))
      |> Enum.map(&marker/1)

    problem_markers ++ latest_markers
  end

  defp marker(%JobRun{} = run) do
    label = JobRun.label(run)

    %{
      id: run.id,
      node_id: Graph.node_id(run),
      node_label: label,
      label: "#{label}: #{state_word(run.state)} #{LocalTime.stamp(moment(run))}",
      initials: initials(run.state),
      status: status(run.state),
      link: {AshEnterprise.Lineage.Run, run.lineage_run_id}
    }
  end

  defp status(:failed), do: :failed
  defp status(:running), do: :executing
  defp status(:complete), do: :done

  defp state_word(:failed), do: "failed"
  defp state_word(:running), do: "running since"
  defp state_word(:complete), do: "completed"

  defp moment(%JobRun{state: :running, started_at: started_at}), do: started_at
  defp moment(%JobRun{last_event_at: at}), do: at

  defp initials(:failed), do: "!"
  defp initials(:running), do: "…"
  defp initials(:complete), do: "✓"
end
