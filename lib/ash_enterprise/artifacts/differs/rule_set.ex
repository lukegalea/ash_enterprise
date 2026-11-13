defmodule AshEnterprise.Artifacts.Differs.RuleSet do
  @moduledoc """
  Two revisions of a rule set (`AshCompliance.Resources.RuleSetRevision`), compared by
  `AshCompliance.RuleSet.Diff` over the rule bundle they pin (`rules_json`), never its
  text: the layer and combining algorithm, each rule by its id, and each fact the rules
  read.

  A bundle that does not decode is an error, not an empty rule set.

  The package owns the comparison, so it changes with the bundle format it reads. This
  module gives the aspects their labels in this application's catalogue and turns the
  package's plain change maps into `AshEnterprise.Artifacts.Change`s.
  """

  @behaviour AshEnterprise.Artifacts.Differ

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Artifacts.Change

  @impl true
  def aspects do
    [
      layer: dgettext_noop("artifacts", "Layer"),
      rules: dgettext_noop("artifacts", "Rules"),
      facts: dgettext_noop("artifacts", "Facts")
    ]
  end

  @impl true
  def diff(old, new, _opts) do
    with {:ok, changes} <- AshCompliance.RuleSet.Diff.diff(old, new) do
      {:ok, Enum.map(changes, &struct!(Change, &1))}
    end
  end
end
