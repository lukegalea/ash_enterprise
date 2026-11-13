defmodule AshEnterprise.Artifacts.Differs.Decision do
  @moduledoc """
  Two versions of a decision definition (`AshEnterprise.Decisions.Definition`), compared
  by `AshDecisions.Diff` over the compiled DMN snapshot (`graph`), never the XML: the
  decisions, the inputs, outputs and rules of each decision table, and the input data the
  model declares.

  The package owns the comparison, so it changes with the snapshot format it reads. This
  module gives the aspects their labels in this application's catalogue and turns the
  package's plain change maps into `AshEnterprise.Artifacts.Change`s.
  """

  @behaviour AshEnterprise.Artifacts.Differ

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Artifacts.Change

  @impl true
  def aspects do
    [
      decisions: dgettext_noop("artifacts", "Decisions"),
      inputs: dgettext_noop("artifacts", "Inputs"),
      outputs: dgettext_noop("artifacts", "Outputs"),
      rules: dgettext_noop("artifacts", "Rules"),
      input_data: dgettext_noop("artifacts", "Input data")
    ]
  end

  @impl true
  def diff(old, new, _opts),
    do: {:ok, Enum.map(AshDecisions.Diff.diff(old, new), &struct!(Change, &1))}
end
