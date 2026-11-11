defmodule AshEnterprise.Decisions.Trial do
  @moduledoc """
  Trying a decision version against sample inputs, before anyone relies on it.

  A trial is a question about the model, not a decision about a case. It evaluates the
  definition it is handed with `record: false` and names no evaluation resource, so no
  `Evaluation` row is written, no trace feeds the evidence trail, and nothing downstream can
  mistake a rehearsal for a real decision. The engine's own account of which rules matched
  comes back with the answer.

  Authority is the reader's own. Versions are read as the signed-in actor in the actor's
  tenant, through the definition's read policy, so someone who may not read a decision cannot
  try it, and a tenant cannot reach another tenant's draft. Nothing here runs as a system
  actor.
  """

  alias AshDecisions.Evaluator
  alias AshDecisions.Tck.Xml
  alias AshEnterprise.Decisions.Definition

  @typedoc "One input the document declares: its name and the FEEL type the author gave it."
  @type input :: %{name: String.t(), type: String.t()}

  @doc """
  The versions of decision `key` the actor may read in `tenant`, drafts and published first.

  An empty list means there is nothing to try, whether the key does not exist, belongs to
  another tenant, or the actor has no read on it; the three are indistinguishable by design.
  """
  @spec versions(String.t(), term(), term()) :: [struct()]
  def versions(key, actor, tenant) when is_binary(key) do
    Definition
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
    |> Ash.Query.do_filter(key: key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.read!()
  end

  @doc "One version the actor may read, by id, or `nil`. Re-read on every trial."
  @spec version(String.t(), String.t(), term(), term()) :: struct() | nil
  def version(key, id, actor, tenant) do
    Definition
    |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
    |> Ash.Query.do_filter(key: key, id: id)
    |> Ash.read_one!()
  rescue
    Ash.Error.Invalid -> nil
  end

  @doc "The names of the decisions in a compiled definition; empty when it did not compile."
  @spec decisions(struct()) :: [String.t()]
  def decisions(%{graph: %{"decisions" => decisions}}) when is_map(decisions) do
    decisions |> Map.values() |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1) |> Enum.sort()
  end

  def decisions(_definition), do: []

  @doc "The inputs a document declares, in document order."
  @spec inputs(struct()) :: [input()]
  def inputs(%{xml: xml}) when is_binary(xml) do
    case Xml.parse(xml) do
      {:ok, root} ->
        root
        |> Xml.descendants("inputData")
        |> Enum.map(fn element ->
          variable = Xml.child(element, "variable")
          %{name: Xml.attr(element, "name"), type: variable && Xml.attr(variable, "typeRef")}
        end)
        |> Enum.reject(&is_nil(&1.name))

      _ ->
        []
    end
  end

  def inputs(_definition), do: []

  @doc """
  Casts the text a person typed into the typed values the engine expects.

  Returns `{:ok, inputs}` or `{:error, %{name => reason}}` with one reason atom per field that
  could not be read: `:blank`, `:not_a_number`, `:not_a_boolean` or `:not_a_date`.
  """
  @spec cast([input()], map()) :: {:ok, map()} | {:error, %{String.t() => atom()}}
  def cast(declared, raw) when is_map(raw) do
    {values, errors} =
      Enum.reduce(declared, {%{}, %{}}, fn %{name: name, type: type}, {values, errors} ->
        case cast_one(type, raw |> Map.get(name, "") |> to_string() |> String.trim()) do
          {:ok, value} -> {Map.put(values, name, value), errors}
          {:error, reason} -> {values, Map.put(errors, name, reason)}
        end
      end)

    if errors == %{}, do: {:ok, values}, else: {:error, errors}
  end

  defp cast_one(_type, ""), do: {:error, :blank}

  defp cast_one(type, text) when type in ["number", "integer", "long", "double"] do
    case Decimal.parse(text) do
      {%Decimal{} = number, ""} ->
        if Decimal.nan?(number) or Decimal.inf?(number),
          do: {:error, :not_a_number},
          else: {:ok, number}

      _ ->
        {:error, :not_a_number}
    end
  end

  defp cast_one("boolean", "true"), do: {:ok, true}
  defp cast_one("boolean", "false"), do: {:ok, false}
  defp cast_one("boolean", _text), do: {:error, :not_a_boolean}

  defp cast_one("date", text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :not_a_date}
    end
  end

  defp cast_one(_type, text), do: {:ok, text}

  @doc """
  Evaluates `definition` against `inputs`, recording nothing.

  The result is the evaluator's, with `:matched_rules` added: the matched rule ids resolved to
  their position and description in the document.
  """
  @spec run(struct(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def run(definition, inputs, decision \\ nil) do
    opts = if decision, do: [decision: decision, record: false], else: [record: false]

    with {:ok, result} <- Evaluator.evaluate(definition, inputs, opts) do
      {:ok, Map.put(result, :matched_rules, matched_rules(definition, result))}
    end
  end

  defp matched_rules(%{graph: %{"decisions" => decisions}}, result) do
    rules =
      decisions
      |> Map.values()
      |> Enum.find(%{}, &(&1["name"] == result.decision))
      |> Map.get("rules", [])

    for id <- result.matched_rule_ids do
      case Enum.find_index(rules, &(&1["id"] == id)) do
        nil -> %{id: id, position: nil, description: nil}
        index -> %{id: id, position: index + 1, description: Enum.at(rules, index)["description"]}
      end
    end
  end

  defp matched_rules(_definition, result),
    do: Enum.map(result.matched_rule_ids, &%{id: &1, position: nil, description: nil})
end
