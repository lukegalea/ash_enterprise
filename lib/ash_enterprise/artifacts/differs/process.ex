defmodule AshEnterprise.Artifacts.Differs.Process do
  @moduledoc """
  Two versions of a process definition (`AshEnterprise.Bpmn.Definition`), compared by
  `AshBpmn.Diff` over the graph the engine runs (`graph`, compiled from the BPMN at save),
  never the XML: the steps (each node and its configuration), the routing (each sequence
  flow and its condition), and the node the process starts at.

  Diagram layout is not compared: moving a shape changes nothing a case does. A version
  whose graph did not compile is compared as having no steps, and its validation says why.

  The package owns the comparison, so it changes with the graph format it reads. This
  module gives the aspects their labels in this application's catalogue and turns the
  package's plain change maps into `AshEnterprise.Artifacts.Change`s.
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
  def diff(old, new, _opts),
    do: {:ok, Enum.map(AshBpmn.Diff.diff(old, new), &struct!(Change, &1))}
end
