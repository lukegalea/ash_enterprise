defmodule AshEnterprise.Artifacts.Differs.Mapping do
  @moduledoc """
  Two versions of a schema mapping (`AshEnterprise.Mdm.Mapping`), compared by
  `AshMdm.Mapping.Diff`: the target (the direction, source, stream and resource the
  mapping writes) and each field rule by the field it writes.

  Rule order is not compared: rules do not chain, so their order changes nothing a
  record becomes (`AshMdm.Mapping.Evaluator`).

  The package owns the comparison, so it changes with the mapping format it reads. This
  module gives the aspects their labels in this application's catalogue and turns the
  package's plain change maps into `AshEnterprise.Artifacts.Change`s.
  """

  @behaviour AshEnterprise.Artifacts.Differ

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Artifacts.Change

  @impl true
  def aspects do
    [
      target: dgettext_noop("artifacts", "Target"),
      fields: dgettext_noop("artifacts", "Fields")
    ]
  end

  @impl true
  def diff(old, new, _opts),
    do: {:ok, Enum.map(AshMdm.Mapping.Diff.diff(old, new), &struct!(Change, &1))}
end
