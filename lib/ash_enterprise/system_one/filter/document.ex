defmodule AshEnterprise.SystemOne.Filter.Document do
  @moduledoc """
  The typed decode pass over a Basic CQL2-JSON document (S1-65; S1-57 §4,
  §5b): one walk that validates and builds the internal tree.

  The wire schema (`Filter.Schema`) has already restricted property names
  to the declared queryables; this pass finishes what JSON Schema cannot
  say across positions — the question-proposal "vocabulary pass" applied to
  filters:

  - per-operator arity and operand shapes (a comparison is property ↔
    literal; property–property comparisons are the §7.10 class and are
    OUTSIDE the Basic slice — refused, never approximated);
  - property↔literal type agreement (a boolean property refuses `"yes"`,
    an integer property refuses `80.0` — strict, non-coercing, the IR's
    own equality discipline);
  - enum membership for closed vocabularies (Choice options, the status
    words);
  - ordering operators only on numeric properties;
  - `in` lists non-empty, homogeneous, property-typed.

  Every failure is a readable refusal string; the caller (the proposal
  mechanism) retains the raw output verbatim. Nothing here executes and
  nothing here consults a model.
  """

  alias AshEnterprise.SystemOne.Filter.Queryables.Property

  @ops %{
    "=" => :eq,
    "<>" => :neq,
    "<" => :lt,
    "<=" => :lte,
    ">" => :gt,
    ">=" => :gte,
    "in" => :in,
    "and" => :and,
    "or" => :or,
    "isNull" => :is_null
  }

  @ordering [:lt, :lte, :gt, :gte]

  @max_depth 16

  @doc "The operator words the Basic slice admits, mapped to their internal atoms."
  @spec ops() :: %{String.t() => atom()}
  def ops, do: @ops

  @doc """
  Validates one document against the declared queryables and builds the
  internal tree. Returns `{:ok, ast}` or a readable refusal.
  """
  @spec decode(term(), [Property.t()]) :: {:ok, map()} | {:error, String.t()}
  def decode(document, queryables)

  def decode(%{"op" => op, "args" => args} = document, queryables) when is_map(document) do
    index = Map.new(queryables, &{&1.name, &1})

    with {:ok, op_atom} <- operator(op),
         :ok <- known_keys(document) do
      node(op_atom, args, index, 0)
    end
  end

  def decode(_document, _queryables) do
    {:error, "a filter document is a single {\"op\", \"args\"} node"}
  end

  ## Node walks

  defp node(op, args, index, depth) when op in [:and, :or] do
    with :ok <- args(args, 2, :infinity, op),
         :ok <- depth(depth) do
      trees = Enum.map(args, &child(&1, index, depth + 1))

      case Enum.find(trees, &match?({:error, _}, &1)) do
        nil -> {:ok, %{op: op, args: Enum.map(trees, fn {:ok, tree} -> tree end)}}
        error -> error
      end
    end
  end

  defp node(:is_null, args, index, _depth) do
    with :ok <- args(args, 1, 1, "isNull"),
         {:ok, property} <- property_operand(Enum.at(args, 0), index) do
      {:ok, %{op: :is_null, property: property}}
    end
  end

  defp node(:in, args, index, _depth) do
    with :ok <- args(args, 2, 2, "in"),
         {:ok, property} <- property_operand(Enum.at(args, 0), index),
         literals when is_list(literals) <- Enum.at(args, 1) do
      list(property, literals)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "the second operand of `in` must be a non-empty list of literals"}
    end
  end

  defp node(op, args, index, _depth) when op in [:eq, :neq, :lt, :lte, :gt, :gte] do
    with :ok <- args(args, 2, 2, to_string(op)),
         {:ok, left} <- operand(Enum.at(args, 0), index),
         {:ok, right} <- operand(Enum.at(args, 1), index),
         {:ok, property, literal} <- sides(left, right, op) do
      if op in @ordering and property.type not in [:integer, :number] do
        {:error,
         "ordering comparison #{op_word(op)} is admitted on numeric properties only — " <>
           "#{property.name} is #{property.type}"}
      else
        {:ok, %{op: op, property: property, literal: literal}}
      end
    end
  end

  defp node(_op, _args, _index, _depth) do
    {:error, "unknown operator"}
  end

  ## Operands

  defp property_operand(%{"property" => name} = operand, index) when map_size(operand) == 1 do
    case Map.fetch(index, name) do
      {:ok, property} -> {:ok, property}
      :error -> {:error, "ghost property #{inspect(name)} — not a declared queryable"}
    end
  end

  defp property_operand(%{"property" => _}, _index) do
    {:error, "a property operand carries only {\"property\": name}"}
  end

  defp property_operand(_other, _index) do
    {:error, "expected a property operand {\"property\": name}"}
  end

  defp operand(%{"property" => _} = operand, index) do
    case property_operand(operand, index) do
      {:ok, property} -> {:ok, {:property, property}}
      error -> error
    end
  end

  defp operand(literal, _index) when is_binary(literal), do: {:ok, {:literal, literal}}
  defp operand(literal, _index) when is_number(literal), do: {:ok, {:literal, literal}}
  defp operand(literal, _index) when is_boolean(literal), do: {:ok, {:literal, literal}}

  defp operand(_other, _index) do
    {:error, "an operand is a declared property or a scalar literal (string, number, boolean)"}
  end

  # Exactly one side is the property, the other the literal. Both sides
  # properties is the §7.10 class (outside Basic); both literals is a
  # constant. Neither runs.
  defp sides({:literal, _}, {:literal, _}, op),
    do:
      {:error, "both operands of #{op_word(op)} are literals — a constant comparison is refused"}

  defp sides({:property, property}, {:literal, literal}, _op),
    do: typed(property, literal)

  defp sides({:literal, literal}, {:property, property}, _op),
    do: typed(property, literal)

  defp sides(_left, _right, op),
    do:
      {:error,
       "property-to-property comparisons are outside the Basic profile — " <>
         "#{op_word(op)} compares one declared property with one literal"}

  defp typed(property, literal) do
    if literal_type_ok?(property, literal) do
      {:ok, property, literal}
    else
      {:error,
       "literal #{inspect(literal)} does not type-check against #{property.name} " <>
         type_phrase(property)}
    end
  end

  defp type_phrase(%Property{type: :string, enum: enum}) when is_list(enum),
    do: "(string, one of #{Enum.join(enum, " | ")})"

  defp type_phrase(%Property{type: type}), do: "(#{type})"

  defp literal_type_ok?(%Property{type: :boolean}, literal) when is_boolean(literal), do: true

  defp literal_type_ok?(%Property{type: :string, enum: nil}, literal) when is_binary(literal),
    do: true

  defp literal_type_ok?(%Property{type: :string, enum: enum}, literal)
       when is_binary(literal),
       do: literal in enum

  defp literal_type_ok?(%Property{type: :integer}, literal) when is_integer(literal), do: true

  defp literal_type_ok?(%Property{type: :number}, literal)
       when is_integer(literal) or is_float(literal),
       do: true

  defp literal_type_ok?(%Property{type: :status, enum: enum}, literal)
       when is_binary(literal),
       do: literal in enum

  defp literal_type_ok?(_property, _literal), do: false

  defp list(property, literals) do
    if Enum.all?(literals, &literal_type_ok?(property, &1)) do
      {:ok, %{op: :in, property: property, literals: literals}}
    else
      {:error,
       "the `in` list for #{property.name} must be non-empty and every element must type-check " <>
         type_phrase(property)}
    end
  end

  defp child(arg, index, depth) do
    case arg do
      %{"op" => op, "args" => args} when is_binary(op) and is_list(args) ->
        with {:ok, op_atom} <- operator(op),
             :ok <- known_keys(arg) do
          node(op_atom, args, index, depth)
        end

      _other ->
        {:error, "logical operands are filter documents ({\"op\", \"args\"}), nothing else"}
    end
  end

  ## Shape helpers

  defp operator(op) do
    case Map.fetch(@ops, op) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         "unsupported operator #{inspect(op)} — the Basic profile admits " <>
           Enum.map_join(@ops, ", ", &elem(&1, 0))}
    end
  end

  defp known_keys(document) do
    keys = MapSet.new(Map.keys(document)) |> MapSet.delete("_comment")

    if MapSet.subset?(keys, MapSet.new(["op", "args"])) do
      :ok
    else
      {:error, "a filter node carries only \"op\" and \"args\""}
    end
  end

  defp args(args, min, max, op) when is_list(args) do
    count = length(args)

    max =
      case max do
        :infinity -> count
        max -> max
      end

    if count >= min and count <= max do
      :ok
    else
      {:error, "#{op} takes #{min_count(min, max)} operand(s), got #{count}"}
    end
  end

  defp args(_other, _min, _max, op), do: {:error, "#{op} takes a list of operands"}

  defp min_count(min, min), do: min
  defp min_count(min, max), do: "#{min}-#{max}"

  defp depth(depth) when depth < @max_depth, do: :ok
  defp depth(_depth), do: {:error, "filter nesting deeper than #{@max_depth} levels is refused"}

  defp op_word(op) do
    Enum.find_value(@ops, fn {word, atom} -> if atom == op, do: word end)
  end
end
