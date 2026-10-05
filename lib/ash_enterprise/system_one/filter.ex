defmodule AshEnterprise.SystemOne.Filter do
  @moduledoc """
  NL search as an editable filter proposal (S1-65; S1-56 §3, S1-57 §5b) —
  the module that names the mechanism and holds its shared pieces:

  - `AshEnterprise.SystemOne.Filter.Queryables` — the declared queryable
    vocabulary of the facts surface.
  - `AshEnterprise.SystemOne.Filter.Schema` — the DERIVED wire JSON Schema
    (Basic CQL2, properties restricted to the vocabulary).
  - `AshEnterprise.SystemOne.Filter.Document` — the typed decode pass.
  - `AshEnterprise.SystemOne.Filter.Compiler` — the deterministic plan +
    three-partition fold.
  - `AshEnterprise.SystemOne.Filter.Runner` — the person-approved run path.
  - `AshEnterprise.SystemOne.FilterProposal` — the versioned, editable,
    never-auto-run proposal artefact.
  - `AshEnterprise.SystemOne.FilterExecution` — the audit row for every
    executed query.

  The discipline the whole cluster enforces (S1-56 §3.1): there is no path
  that executes model output unedited, and no path that filters silently.
  """

  alias AshEnterprise.SystemOne.Filter.Queryables.Property

  @doc """
  The prompt sent with the search text: the derived schema rides the wire
  as the structured-output contract, and the prose says only what the
  schema cannot — the declared vocabulary with its types, the Basic
  operator set, and the three-valued pins (the unknown partition is
  queried explicitly with `isNull` or a `.status` clause; it is never
  `false`).
  """
  @spec build_prompt(String.t(), [Property.t()]) :: String.t()
  def build_prompt(nl_text, queryables) do
    """
    You are translating one natural-language search into a candidate filter
    document (Basic CQL2, JSON) over the facts surface. The document is a
    PROPOSAL a person will edit and approve — it never runs unedited, so
    precision beats recall: when the search does not map to the declared
    vocabulary, emit the narrowest honest document, never a guess.

    Rules, in order of importance:

    - Property names come ONLY from the declared queryables below. A name
      that is not listed cannot decode.
    - Operators: = < > <= >= <> in and or isNull. Nothing else.
    - The surface is three-valued: a property with no fact is UNKNOWN,
      never false. To address the unknown partition use isNull on the
      property, or compare its "<property>.status" field with
      "not_assessed" / "stale". Never encode unknown as false.
    - Ordering comparisons (< <= > >=) only on numeric properties.
    - Equality/disjunction on enum properties uses ONLY their listed words.
    - Every judged predicate also has a "<property>.status" field with the
      words: admitted_true | admitted_false | review | not_assessed | stale.
    - Output only JSON matching the provided schema: one {"op", "args"}
      tree. No commentary, no extra keys.

    Declared queryables:

    #{render_queryables(queryables)}

    Search request:

    #{nl_text}
    """
  end

  defp render_queryables(queryables) do
    Enum.map_join(queryables, "\n", fn %Property{} = property ->
      "- #{property.name} — #{render_type(property)}" <> render_enum(property)
    end)
  end

  defp render_type(%Property{kind: :judged, type: type}),
    do: "#{type} (judged predicate; a fact's absence reads UNKNOWN)"

  defp render_type(%Property{kind: :crisp, type: type}),
    do: "#{type} (crisp attribute; a fact's absence reads UNKNOWN)"

  defp render_type(%Property{type: type}), do: "#{type}"

  defp render_enum(%Property{enum: enum}) when is_list(enum),
    do: ", one of: " <> Enum.join(enum, " | ")

  defp render_enum(_property), do: ""
end
