defmodule AshEnterprise.Artifacts.Differs.Process do
  @moduledoc """
  Two versions of a process definition (`AshEnterprise.Bpmn.Definition`), compared over
  the graph the engine runs (`graph`, compiled from the BPMN at save), never the XML:

    * **steps**: each node by its id, added or removed, and for a node in both, each
      property of its configuration that changed: its type, name, the action or call a
      task runs, the decision a rule task consults, who a user task goes to, its timers
      and outcomes;
    * **routing**: each sequence flow by its id, where it goes from and to, and its
      condition;
    * **start**: which node the process starts at.

  Diagram layout is not compared: moving a shape changes nothing a case does. A version
  whose graph did not compile is compared as having no steps, and its validation says why.
  """

  @behaviour AshEnterprise.Artifacts.Differ

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Artifacts.Change

  @impl true
  def aspects do
    [
      steps: dgettext_noop("artifacts", "Steps"),
      routing: dgettext_noop("artifacts", "Routing"),
      start: dgettext_noop("artifacts", "Start")
    ]
  end

  @impl true
  def diff(old, new, _opts) do
    old_graph = old.graph || %{}
    new_graph = new.graph || %{}

    {:ok,
     Change.keyed(:steps, old_graph["nodes"] || %{}, new_graph["nodes"] || %{}) ++
       Change.keyed(:routing, old_graph["flows"] || %{}, new_graph["flows"] || %{}) ++
       Change.value(:start, old_graph["start"], new_graph["start"])}
  end
end
