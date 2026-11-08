defmodule AshEnterprise.Artifacts.Differs.AgentVersion do
  @moduledoc """
  Two versions of an agent (`AshEnterprise.Execution.AgentVersion`), by what they let a
  run do:

    * **authority**: who a run acts as, and whether it may start with no person asking;
    * **tools**: each target in the toolset, added or removed, and a target whose
      declaration changed (its digest);
    * **model**: the model profile;
    * **limits**: each bound (steps, tool calls, deadline, token budget, repairs);
    * **output**: the type a run's output is cast to;
    * **instructions**: whether the prompt changed, and its length. The text itself
      is not diffed here: what a changed prompt does is what an evaluation measures.
  """

  @behaviour AshEnterprise.Artifacts.Differ

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Artifacts.Change

  @impl true
  def aspects do
    [
      authority: dgettext_noop("artifacts", "Authority"),
      tools: dgettext_noop("artifacts", "Tools"),
      model: dgettext_noop("artifacts", "Model"),
      limits: dgettext_noop("artifacts", "Limits"),
      output: dgettext_noop("artifacts", "Output"),
      instructions: dgettext_noop("artifacts", "Instructions")
    ]
  end

  @impl true
  def diff(old, new, _opts) do
    {:ok,
     Enum.concat([
       authority(old, new),
       Change.keyed(:tools, tools(old.toolset), tools(new.toolset)),
       Change.value(:model, old.model_profile, new.model_profile),
       Change.keyed(:limits, limits(old.limits), limits(new.limits)),
       Change.value(:output, old.output_type, new.output_type),
       instructions(old.instructions, new.instructions)
     ])}
  end

  @doc "Who a version's runs act as, in words: `requester` or `automation:<name>`."
  @spec authority(map() | nil) :: String.t() | nil
  def authority(nil), do: nil

  def authority(%{} = authority) do
    case {field(authority, :type), field(authority, :name)} do
      {type, nil} -> to_string(type)
      {type, name} -> "#{type}:#{name}"
    end
  end

  defp authority(old, new) do
    Change.value(:authority, authority(old.authority), authority(new.authority)) ++
      Change.value(:authority, old.requesterless, new.requesterless, "requesterless")
  end

  # A tool by its target, valued by the digest of its declaration when written.
  defp tools(toolset),
    do: Map.new(toolset || [], &{field(&1, :target), field(&1, :target_digest)})

  defp limits(nil), do: %{}
  defp limits(limits), do: Map.new(limits, fn {name, value} -> {to_string(name), value} end)

  defp instructions(same, same), do: []

  defp instructions(old, new) do
    [
      %Change{
        aspect: :instructions,
        kind: :changed,
        option: "length",
        from: String.length(old || ""),
        to: String.length(new || "")
      }
    ]
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
