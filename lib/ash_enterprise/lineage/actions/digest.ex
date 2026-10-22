defmodule AshEnterprise.Lineage.Actions.Digest do
  @moduledoc """
  `Console.lineage`: the lineage graph for a window as plain text, for a
  terminal transcript (the ACP `lineage` prompt) — how many jobs and
  datasets, then the failed and running runs first, then each job's latest
  run. Names, states and times only: what the graph shows.

  Read as the actor in their tenant (`AshEnterprise.Lineage.Graph`).
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Lineage.{Graph, JobRun, Window}
  alias AshEnterprise.Platform.LocalTime

  @max_lines 20

  @impl true
  def run(input, _opts, context) do
    window = input.arguments |> Map.get(:window, :day) |> to_string()
    opts = Ash.Context.to_opts(context)

    case Graph.derive(actor: opts[:actor], tenant: opts[:tenant], window: window) do
      {:ok, graph} -> {:ok, render(graph, Window.fetch(window))}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def render(%{jobs: []}, window), do: "Lineage, #{String.downcase(window.label)}: no runs."

  def render(graph, window) do
    jobs = length(graph.jobs)
    datasets = Enum.count(graph.nodes, &(&1.kind == :dataset))
    failed = Enum.count(graph.runs, &(&1.state == :failed))
    running = Enum.count(graph.runs, &(&1.state == :running))

    header =
      "Lineage, #{String.downcase(window.label)} — #{jobs} jobs, #{datasets} datasets" <>
        counts(failed, running)

    problems = Enum.filter(graph.runs, &(&1.state in [:failed, :running]))
    shown = MapSet.new(problems, & &1.id)

    latest =
      graph.runs
      |> Enum.filter(&(&1.state == :complete and not MapSet.member?(shown, &1.id)))
      |> Enum.uniq_by(& &1.job_id)

    lines = (problems ++ latest) |> Enum.take(@max_lines) |> Enum.map(&line/1)

    Enum.join([header | lines] ++ ["Open it on the web: /app/lineage"], "\n")
  end

  defp counts(0, 0), do: "."
  defp counts(failed, 0), do: ", #{failed} failed."
  defp counts(0, running), do: ", #{running} running."
  defp counts(failed, running), do: ", #{failed} failed, #{running} running."

  defp line(%JobRun{state: :failed} = run),
    do: "  ✕ #{JobRun.label(run)} — failed #{LocalTime.stamp(run.last_event_at)}#{reason(run)}"

  defp line(%JobRun{state: :running} = run),
    do: "  … #{JobRun.label(run)} — running since #{LocalTime.stamp(run.started_at)}"

  defp line(%JobRun{} = run),
    do: "  ✓ #{JobRun.label(run)} — completed #{LocalTime.stamp(run.last_event_at)}"

  defp reason(%JobRun{error_message: message}) when is_binary(message), do: ": " <> message
  defp reason(_run), do: ""
end
