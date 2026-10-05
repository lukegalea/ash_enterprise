defmodule AshEnterprise.SystemOne.Filter.Compiler do
  @moduledoc """
  The deterministic half of the run path (S1-65; S1-56 §3.4, S1-57 §5b):
  an approved Basic-CQL2 document becomes a compiled plan over the facts
  surface, and the plan folds actor-visible facts into the three
  partitions.

  Two properties carry the design:

  - **No model anywhere.** The fold is a pure function; the read that
    feeds it is an ordinary Ash read as the actor, through the facts
    surface's own policies. A judged predicate cannot widen what the actor
    may see — the fold only ever sees rows the actor's read returned
    (ADR 0048, law 15).
  - **Kleene three-valued evaluation.** A comparison against an absent or
    expired fact is `:unknown` (the profile fixes judged properties to
    unknown-on-absence, S1-57 §4 rows 6/7); `and` is false-dominant, `or`
    is true-dominant, and the result sets never fold unknown away — it
    comes back as the `unknown` partition, which is the assess action's
    input. Equality is strict and non-coercing (`80` ≠ `80.0`, the IR's
    own discipline; S1-57 §4 row 15).

  Local pins where the OGC text is silent (S1-57 §5b):
  `in` with an unknown left operand is `:unknown`; `isNull` on a derived
  status field is always false (status fields are total — `not_assessed`
  IS the unknown partition's spelling).
  """

  alias AshEnterprise.SystemOne.Filter.Queryables.Property
  alias AshJudgments.Facts

  @type three :: boolean() | :unknown

  @doc """
  Compiles a decoded document into the plan recorded on every execution:
  the referenced properties, the operators used, and the request-time
  parameters the document does not carry (scope, minimum admission grade —
  scope binds at request time, S1-57 §6).
  """
  @spec compile(map(), keyword()) :: {:ok, map()}
  def compile(ast, opts \\ []) do
    {:ok,
     %{
       "strategy" => "surface_fold",
       "predicates" => ast |> properties() |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort(),
       "operators" => ast |> operators() |> Enum.uniq() |> Enum.sort() |> Enum.map(&to_string/1),
       "min_grade" => to_string(Keyword.get(opts, :min_grade, :grant)),
       "scope" => Keyword.get(opts, :scope)
     }}
  end

  @doc """
  Folds subject-grouped facts through the document. `facts_by_subject`
  maps `{subject_type, subject_id}` to a `%{"predicate" => fact}` map of
  that subject's actor-visible current facts; `scope` (exact match — the
  runner's request-time parameter) and `now` decide participation and
  freshness.

  Returns the three partitions: subjects whose evaluation is TRUE, FALSE
  and `:unknown`. Unknown-partition entries carry the referenced
  predicates that were unknown for that subject — the assess action's
  triage input.
  """
  @spec fold(map(), %{}, map() | nil, DateTime.t()) :: %{
          in: [map()],
          out: [map()],
          unknown: [map()]
        }
  def fold(ast, facts_by_subject, scope, now) do
    kinds = kinds(ast)

    facts_by_subject
    |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
    |> Enum.map(fn {{subject_type, subject_id}, facts} ->
      facts = scope_filter(facts, scope)
      subject = %{"subject_type" => subject_type, "subject_id" => subject_id}

      case evaluate(ast, facts, now) do
        true -> {:in, subject}
        false -> {:out, subject}
        :unknown -> {:unknown, Map.put(subject, "missing", missing(ast, facts, kinds, now))}
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> then(fn grouped ->
      %{
        in: Map.get(grouped, :in, []),
        out: Map.get(grouped, :out, []),
        unknown: Map.get(grouped, :unknown, [])
      }
    end)
  end

  ## Kleene evaluation

  @doc "Evaluates the document for one subject's facts: `true`, `false` or `:unknown`."
  @spec evaluate(map(), %{}, DateTime.t()) :: three()
  def evaluate(%{op: :and, args: args}, facts, now) do
    results = Enum.map(args, &evaluate(&1, facts, now))

    cond do
      false in results -> false
      :unknown in results -> :unknown
      true -> true
    end
  end

  def evaluate(%{op: :or, args: args}, facts, now) do
    results = Enum.map(args, &evaluate(&1, facts, now))

    cond do
      true in results -> true
      :unknown in results -> :unknown
      true -> false
    end
  end

  def evaluate(%{op: :is_null, property: property}, facts, now) do
    case value(property, facts, now) do
      :unknown -> true
      {:ok, _value} -> false
    end
  end

  def evaluate(%{op: op, property: property, literal: literal}, facts, now)
      when op in [:eq, :neq] do
    case value(property, facts, now) do
      :unknown ->
        :unknown

      {:ok, actual} ->
        if strict_eq?(actual, literal),
          do: op == :eq,
          else: op == :neq
    end
  end

  def evaluate(%{op: op, property: property, literal: literal}, facts, now)
      when op in [:lt, :lte, :gt, :gte] do
    case value(property, facts, now) do
      :unknown -> :unknown
      {:ok, actual} -> compare(op, actual, literal)
    end
  end

  def evaluate(%{op: :in, property: property, literals: literals}, facts, now) do
    case value(property, facts, now) do
      :unknown -> :unknown
      {:ok, actual} -> Enum.any?(literals, &strict_eq?(actual, &1))
    end
  end

  defp compare(op, actual, literal) do
    ordered? = is_number(actual) and is_number(literal)

    case {ordered?, op} do
      {true, :lt} -> actual < literal
      {true, :lte} -> actual <= literal
      {true, :gt} -> actual > literal
      {true, :gte} -> actual >= literal
      # A stored value of the wrong shape compares unknown, never crashes:
      # the facts table is JSON, and the fold is a read, not a validator.
      _ -> :unknown
    end
  end

  # Strict, non-coercing equality: 80 ≠ 80.0, "80" ≠ 80.
  defp strict_eq?(actual, literal), do: actual === literal

  ## Values

  # A derived status field is total: `not_assessed` IS the unknown
  # partition's spelling, so it is never :unknown.
  defp value(%Property{kind: :status, name: name}, facts, now) do
    base = String.replace_suffix(name, ".status", "")

    {:ok,
     case facts[base] do
       nil -> "not_assessed"
       fact -> status_of(fact, now)
     end}
  end

  defp value(%Property{kind: kind, name: name}, facts, now) when kind in [:judged, :crisp] do
    case facts[name] do
      nil -> :unknown
      fact -> if expired?(fact, now), do: :unknown, else: {:ok, fact.value}
    end
  end

  defp status_of(fact, now) do
    cond do
      expired?(fact, now) -> "stale"
      fact.holds -> "admitted_true"
      true -> "admitted_false"
    end
  end

  defp expired?(fact, now) do
    not is_nil(fact.valid_until) and DateTime.compare(fact.valid_until, now) != :gt
  end

  defp scope_filter(facts, nil), do: facts

  defp scope_filter(facts, scope) do
    Map.filter(facts, fn {_name, fact} -> fact.scope == scope end)
  end

  ## Introspection for the plan and the unknown partition

  defp properties(%{op: op, args: args}) when op in [:and, :or],
    do: Enum.flat_map(args, &properties/1)

  defp properties(%{property: property}), do: [property]

  defp operators(%{op: op, args: args}) when op in [:and, :or],
    do: [op | Enum.flat_map(args, &operators/1)]

  defp operators(%{op: op}), do: [op]

  defp kinds(ast) do
    ast |> properties() |> Map.new(&{&1.name, &1.kind})
  end

  defp missing(ast, facts, kinds, now) do
    ast
    |> properties()
    |> Enum.filter(&(&1.kind in [:judged, :crisp]))
    |> Enum.uniq_by(& &1.name)
    |> Enum.filter(&(Map.has_key?(kinds, &1.name) and value(&1, facts, now) == :unknown))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  @doc "The admission grades that satisfy a request-time minimum (Q19)."
  @spec grades_at_least(:grant | :person) :: [:grant | :person]
  def grades_at_least(min_grade) do
    Enum.filter(Facts.grades(), &Facts.grade_at_least?(&1, min_grade))
  end
end
