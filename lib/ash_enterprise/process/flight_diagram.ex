defmodule AshEnterprise.Process.FlightDiagram do
  @moduledoc """
  The process flight views: a BPMN process drawn as a diagram, with a marker
  on every step a run is standing on, moved as the engine advances.

  The `AshA2ui.Diagram.Source` the flight surfaces declare
  (`AshEnterpriseWeb.A2ui.FlightUI` and its siblings). It adapts
  `AshBpmn.FlightView` — `mermaid/2` draws the definition, `token_positions/2`
  says where the tokens are, and its PubSub topics (`topics/2`) say when they
  move — to the diagram contract. Two views:

    * **One run** (`diagram/1`): the instance selected on the surface (its
      `:instance` context, which the deep link `/app/r/flight/<id>` selects),
      or else the newest running one the reader may see. Drawn on the
      definition it pinned, so a run started on an older version shows the
      steps it is actually executing. A finished run shows where it ended.
    * **Every run of one process** (`process/2`): the definition a new run of
      `key` would use (`AshEnterprise.Process.Resolver`), with a marker per
      live token of every running instance the reader may see. A token on a
      step the current version no longer has is left off the drawing.

  ## Who sees what

  Everything about a run is read as the reader, under their policies: the
  instance (a role grant on it, or `AshEnterprise.Security.Checks.TaskInstance`
  for someone asked to decide one of its steps), its tokens, its tasks and
  its subject. A run the reader may not read contributes nothing — no marker,
  no count. The selected run is read again here rather than trusted from the
  surface. A marker is labelled with the run's subject as the reader may see
  it (`subject_label`): someone who may read the run but not its subject sees
  the subject's kind ("Morning brief"), never its content.

  The definition is configuration, not data about anyone, and most runs pin a
  platform baseline that a tenant-scoped read cannot see, so it is found the
  way the engine finds it (`AshEnterprise.Process.DefinitionLoader`). Node
  labels are the definition's own step names.

  ## Not built: simulated runs

  Simulated runs shown beside live ones under a SIMULATION badge wait on a
  simulator (ash_bpsim) that does not exist yet. The seam is the position
  list: markers are built from `AshBpmn.FlightView` position maps, so a
  simulator that emits the same maps can be drawn on the same diagram by a
  second `diagram` entity, without a second adapter.
  """

  @behaviour AshA2ui.Diagram.Source

  require Ash.Query

  alias AshBpmn.FlightView
  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.{DefinitionLoader, Resolver}

  @live_statuses [:active, :executing, :waiting]
  @every_status [:active, :executing, :waiting, :consumed, :dead]
  @every_instance_status [:running, :completed, :failed, :errored, :cancelled, :superseded]
  # A process view shows at most this many runs; beyond it the oldest drop off.
  @max_runs 500

  # -- one run --------------------------------------------------------------------

  @impl true
  def diagram(context) do
    opts = opts(context)

    with {:ok, instance} <- selected_instance(context, opts),
         {:ok, definition} <- pinned_definition(instance),
         {:ok, source} <- FlightView.mermaid(definition) do
      positions = run_positions(instance, definition.graph, opts)
      tasks = waiting_tasks(positions, opts)
      {:ok, %{source: source, markers: run_markers(positions, instance, definition, tasks)}}
    else
      _nothing_to_draw -> {:error, :no_run}
    end
  end

  @doc """
  The instance a one-run view shows for `actor`: the selected `id` when they
  may read it, else (no selection) the newest running one they may read.
  `nil` when there is none.
  """
  @spec instance_for(String.t() | nil, term(), term()) :: struct() | nil
  def instance_for(id, actor, tenant) do
    case selected_instance(%{contexts: %{instance: id}}, actor: actor, tenant: tenant) do
      {:ok, instance} -> instance
      :none -> nil
    end
  end

  defp selected_instance(%{contexts: %{instance: id}}, opts) when is_binary(id) and id != "" do
    case Ash.get(
           Instance,
           id,
           Keyword.merge(opts, not_found_error?: false, load: [:subject_label])
         ) do
      {:ok, %Instance{} = instance} -> {:ok, instance}
      _unreadable -> :none
    end
  end

  defp selected_instance(_context, opts) do
    Instance
    |> Ash.Query.for_read(:running_now, %{}, opts)
    |> Ash.Query.load(:subject_label)
    |> Ash.Query.limit(1)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %Instance{} = instance} -> {:ok, instance}
      _none -> :none
    end
  end

  # A running run's live tokens; a finished one's last tokens, where it ended.
  defp run_positions(%{status: :running} = instance, _graph, opts),
    do: positions([instance.id], @live_statuses, [:running], opts)

  defp run_positions(instance, graph, opts) do
    [instance.id]
    |> positions(@every_status, @every_instance_status, opts)
    |> Enum.filter(&ended?(&1, instance, graph))
  end

  # A failed run stopped where its live tokens are; a completed one at the
  # end event(s) its last tokens were consumed at. The node type is read off
  # the drawn graph, not the position: the position's definition metadata is
  # whatever the reader may read of the definition, often nothing.
  defp ended?(%{status: status}, %{status: run}, _graph) when run in [:failed, :errored],
    do: status in ["active", "executing", "waiting"]

  defp ended?(%{status: status, node_id: node_id}, _completed, graph),
    do: status == "consumed" and get_in(graph, ["nodes", node_id, "type"]) == "endEvent"

  defp run_markers(positions, instance, definition, tasks) do
    graph = definition.graph

    Enum.flat_map(positions, fn position ->
      case node_ref(graph, position.node_id) do
        nil ->
          []

        node ->
          [
            %{
              id: position.token_id,
              node_id: node,
              node_label: node_name(graph, position.node_id),
              label: instance.subject_label || "This run",
              status: marker_status(position.status, instance.status),
              link: task_link(tasks, position.token_id)
            }
          ]
      end
    end)
  end

  # The task a waiting token stands for, as the reader may see it: the marker
  # opens it (Approvals), where it can be decided.
  defp waiting_tasks(positions, opts) do
    token_ids = for %{status: "waiting", token_id: id} <- positions, do: id

    if token_ids == [] do
      %{}
    else
      HumanTask
      |> Ash.Query.filter(token_id in ^token_ids and status in [:open, :claimed])
      |> Ash.read!(opts)
      |> Map.new(&{&1.token_id, &1.id})
    end
  end

  defp task_link(tasks, token_id) do
    case Map.get(tasks, token_id) do
      nil -> nil
      task_id -> {HumanTask, task_id}
    end
  end

  # -- every run of one process ---------------------------------------------------

  @doc """
  The process view of `key` (a `{module, function, args}` diagram source:
  `{FlightDiagram, :process, ["morning.brief"]}`).
  """
  @spec process(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def process(context, key) do
    opts = opts(context)

    with tenant when not is_nil(tenant) <- opts[:tenant],
         {:ok, definition} <- Resolver.resolve(:process, key, tenant),
         {:ok, source} <- FlightView.mermaid(definition) do
      instances = runs(key, opts)
      positions = positions(Enum.map(instances, & &1.id), @live_statuses, [:running], opts)
      {:ok, %{source: source, markers: process_markers(positions, instances, definition)}}
    else
      _nothing_to_draw -> {:error, :no_process}
    end
  end

  @doc "Running instances of process `key` the reader in `opts` may see, newest first."
  @spec runs(String.t(), keyword()) :: [struct()]
  def runs(key, opts) do
    Instance
    |> Ash.Query.for_read(:running_process, %{process: key}, opts)
    |> Ash.Query.load(:subject_label)
    |> Ash.Query.limit(@max_runs)
    |> Ash.read!(opts)
  end

  defp process_markers(positions, instances, definition) do
    graph = definition.graph
    by_id = Map.new(instances, &{&1.id, &1})

    Enum.flat_map(positions, fn position ->
      case {node_ref(graph, position.node_id), by_id[position.instance_id]} do
        {nil, _instance} ->
          []

        {_node, nil} ->
          []

        {node, instance} ->
          [
            %{
              id: position.token_id,
              node_id: node,
              node_label: node_name(graph, position.node_id),
              label: instance.subject_label || "A run",
              status: marker_status(position.status, instance.status),
              # Each run opens on its own flight view.
              link: {"flight", instance.id}
            }
          ]
      end
    end)
  end

  # -- topics ---------------------------------------------------------------------

  @doc """
  The PubSub topics a flight view listens on (`AshBpmn.FlightView`'s
  broadcasts): one run's instance topic, or every version of process `key`'s
  definition topic. A broadcast only prompts a refresh; the refresh reads
  everything again as the reader.
  """
  @spec topics({:instance, String.t() | nil} | {:process, String.t()}, term()) :: [String.t()]
  def topics({:instance, nil}, _tenant), do: []
  def topics({:instance, id}, _tenant), do: [FlightView.instance_topic(id)]

  def topics({:process, key}, tenant),
    do: key |> definition_ids(tenant) |> Enum.map(&FlightView.definition_topic/1)

  # -- shared -----------------------------------------------------------------------

  defp opts(context), do: [actor: context[:actor], tenant: context[:tenant]]

  # Token positions of instances the reader has already been shown, read as
  # the reader (`AshBpmn.FlightView.token_positions/2`).
  defp positions([], _token_statuses, _instance_statuses, _opts), do: []

  defp positions(instance_ids, token_statuses, instance_statuses, opts) do
    FlightView.token_positions!(AshEnterprise.Bpmn,
      instance_ids: instance_ids,
      token_statuses: token_statuses,
      instance_statuses: instance_statuses,
      actor: opts[:actor],
      tenant: opts[:tenant]
    )
  end

  defp pinned_definition(instance) do
    DefinitionLoader.load(Definition, instance.definition_id, instance, %{
      tenant: instance.organization_id
    })
  end

  @doc """
  The ids of every version of process `key` `tenant` could have runs on: its
  own and the platform's baselines. Configuration, read the way the process
  catalogue reads it.
  """
  @spec definition_ids(String.t(), term()) :: [Ash.UUID.t()]
  def definition_ids(_key, nil), do: []

  def definition_ids(key, tenant) do
    [tenant, Resolver.platform_tenant()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn in_tenant ->
      Definition
      |> Ash.Query.filter(key == ^key)
      |> Ash.Query.select([:id])
      |> Ash.read!(actor: SystemActor.process(), tenant: in_tenant)
      |> Enum.map(& &1.id)
    end)
  end

  defp marker_status(_token, run) when run in [:failed, :errored], do: :failed
  defp marker_status("consumed", _run), do: :done
  defp marker_status(token, _run) when token in ["active", "executing", "waiting"], do: token
  defp marker_status(_token, _run), do: :done

  defp node_name(graph, node_id), do: get_in(graph, ["nodes", node_id, "name"]) || node_id

  # The mermaid node id `AshBpmn.FlightView.mermaid/2` gives element
  # `node_id` (its documented sanitizing), or nil when this graph has no such
  # element — a token on a step an older version had.
  defp node_ref(graph, node_id) do
    if Map.has_key?(graph["nodes"] || %{}, node_id) do
      cond do
        node_id == "end" -> "node_end"
        node_id =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/ -> node_id
        true -> "n_" <> String.replace(node_id, ~r/[^A-Za-z0-9_]/, "_")
      end
    end
  end
end
