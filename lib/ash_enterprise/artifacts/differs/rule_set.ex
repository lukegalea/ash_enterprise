defmodule AshEnterprise.Artifacts.Differs.RuleSet do
  @moduledoc """
  Two revisions of a rule set (`AshCompliance.Resources.RuleSetRevision`), compared over
  the rule bundle they pin (`rules_json`, the serialized `AshRules.Ir.Bundle`):

    * **layer**: the layer the rule set contributes to, and its combining algorithm;
    * **rules**: each rule by its id, added or removed, and for one in both its name,
      revision, when it applies, what makes it fail, its outcome and severity, the
      controls it maps to and the evidence it asks for;
    * **facts**: the fact schema the rules read.

  A bundle that does not decode is an error, not an empty rule set.
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
    with {:ok, old_bundle} <- bundle(old),
         {:ok, new_bundle} <- bundle(new) do
      {:ok,
       Change.keyed(:layer, layer(old, old_bundle), layer(new, new_bundle)) ++
         Change.keyed(:rules, rules(old_bundle), rules(new_bundle)) ++
         Change.value(:facts, old_bundle["fact_schema"], new_bundle["fact_schema"])}
    end
  end

  defp bundle(%{rules_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"rules" => rules} = bundle} when is_list(rules) -> {:ok, bundle}
      _other -> {:error, :unreadable_bundle}
    end
  end

  defp bundle(_revision), do: {:error, :unreadable_bundle}

  defp layer(revision, bundle),
    do: %{"layer" => revision.layer, "combining" => bundle["combining"] || revision.combining}

  defp rules(bundle), do: Map.new(bundle["rules"], &{&1["id"], Map.delete(&1, "id")})
end
