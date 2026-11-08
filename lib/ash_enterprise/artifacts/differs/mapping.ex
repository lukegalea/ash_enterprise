defmodule AshEnterprise.Artifacts.Differs.Mapping do
  @moduledoc """
  Two versions of a schema mapping (`AshEnterprise.Mdm.Mapping`):

    * **target**: the direction, source, stream and resource the mapping writes;
    * **fields**: each field rule by the field it writes, added or removed, and for one
      in both the source path, the operator, its arguments and whether it is required.

  Rule order is not compared: rules do not chain, so their order changes nothing a
  record becomes (`AshMdm.Mapping.Evaluator`).
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
  def diff(old, new, _opts) do
    {:ok,
     Change.keyed(:target, target(old), target(new)) ++
       Change.keyed(:fields, fields(old.field_rules), fields(new.field_rules))}
  end

  defp target(mapping) do
    %{
      "direction" => mapping.direction,
      "source" => mapping.source,
      "stream" => mapping.stream,
      "resource" => mapping.target_resource
    }
  end

  defp fields(rules),
    do:
      Map.new(rules || [], fn rule -> {to_string(rule["target"]), Map.delete(rule, "target")} end)
end
