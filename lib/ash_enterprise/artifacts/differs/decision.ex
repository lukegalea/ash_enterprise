defmodule AshEnterprise.Artifacts.Differs.Decision do
  @moduledoc """
  Two versions of a decision definition (`AshEnterprise.Decisions.Definition`), compared
  over the compiled DMN snapshot (`graph`), never the XML:

    * **decisions**: each decision by its id, added or removed, and for one in both its
      name, the decisions and inputs it requires, its hit policy and aggregation;
    * **inputs** and **outputs**: each clause of a decision table by its id, with its
      label, expression and type;
    * **rules**: each rule of a decision table by its id, with its input and output
      entries;
    * **input data**: the inputs the model declares.

  A literal-expression decision is compared by its expression text, which is what it
  evaluates.
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
  def diff(old, new, _opts) do
    old_decisions = decisions(old.graph)
    new_decisions = decisions(new.graph)

    {:ok,
     Change.keyed(:decisions, heads(old_decisions), heads(new_decisions)) ++
       Change.keyed(:inputs, clauses(old_decisions, "inputs"), clauses(new_decisions, "inputs")) ++
       Change.keyed(
         :outputs,
         clauses(old_decisions, "outputs"),
         clauses(new_decisions, "outputs")
       ) ++
       Change.keyed(:rules, clauses(old_decisions, "rules"), clauses(new_decisions, "rules")) ++
       Change.keyed(:input_data, input_data(old.graph), input_data(new.graph))}
  end

  defp decisions(%{"decisions" => %{} = decisions}), do: decisions
  defp decisions(_graph), do: %{}

  # A decision without its table's clauses and rules, which are compared on their own.
  defp heads(decisions),
    do: Map.new(decisions, fn {id, d} -> {id, Map.drop(d, ["inputs", "outputs", "rules"])} end)

  # Each clause or rule keyed by its decision and its own id, so two tables' rules never
  # collide.
  defp clauses(decisions, part) do
    for {id, decision} <- decisions,
        clause <- decision[part] || [],
        into: %{},
        do: {"#{id} #{clause["id"]}", Map.delete(clause, "id")}
  end

  defp input_data(%{"input_data" => %{} = inputs}),
    do: Map.new(inputs, fn {id, input} -> {id, input["name"]} end)

  defp input_data(_graph), do: %{}
end
