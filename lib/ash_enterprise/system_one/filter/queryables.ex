defmodule AshEnterprise.SystemOne.Filter.Queryables do
  @moduledoc """
  The declared queryable vocabulary of the facts surface (S1-65; S1-56 §3.2,
  S1-57 §5b): the property names a filter document may reference, as data.

  Three sources, all declarations — never discovery:

  - **Judged predicates** — every question declared on the host's configured
    subject resources (`config :ash_enterprise, :system_one_subject_resources`),
    named by its `question_id` (the exact predicate spelling a judged fact
    carries in the facts table). The answer type fixes the CQL2 scalar type:
    a Noul is boolean, a Choice is a string whose vocabulary is the declared
    options (the abstention included, law 7), a Score is an integer level.
    Extraction-typed questions are refused at this surface: their values are
    composite, and the Basic profile admits scalars only.
  - **Crisp attributes** — the host's fact-schema entries for directly
    entered facts (RFC §7.4). The v0 slice declares a small synthetic demo
    schema (the spike's own generic vendor vocabulary); a real crisp schema
    replaces this list without touching anything downstream, because every
    consumer derives from this module.
  - **Derived status fields** — one per judged predicate, spelled
    `<question_id>.status`: the frozen interchange enum
    `admitted_true | admitted_false | review | not_assessed | stale`
    (S1-57 §6). The fold never *produces* `review` — an open review task
    reads as `not_assessed` by the materialiser's design (review writes no
    fact) — but the word stays in the enum so exported documents and peer
    systems share one vocabulary.

  The vocabulary is the decode contract's derivation source: the wire JSON
  Schema restricts property names to this list, and the typed validation
  pass checks literals against these types. A property outside the list is
  a refusal, never a silent skip (S1-56 §3.3). Absence semantics are fixed
  here by profile: judged properties read unknown-on-absence, and a scope
  or admission-grade constraint is a request-time runner parameter, never a
  clause in the document.
  """

  @status_words ["admitted_true", "admitted_false", "review", "not_assessed", "stale"]

  defmodule Property do
    @moduledoc """
    One queryable property: its exact name in the facts surface, where it
    comes from, its CQL2 scalar type and, for closed vocabularies, the
    admitted words.
    """

    defstruct [:name, :kind, :type, :enum, :description]

    @type t :: %__MODULE__{
            name: String.t(),
            kind: :judged | :crisp | :status,
            type: :boolean | :string | :integer | :number | :status,
            enum: [String.t()] | nil,
            description: String.t() | nil
          }
  end

  alias AshEnterprise.SystemOne.Filter.Queryables.Property
  alias AshJudgments.Registry.Info

  @doc "The full declared vocabulary: judged predicates, crisp attributes, derived status fields."
  @spec all() :: [Property.t()]
  def all, do: judged() ++ crisp() ++ derived()

  @doc "Every judged predicate declared on the configured subject resources."
  @spec judged() :: [Property.t()]
  def judged do
    subject_resources()
    |> Enum.flat_map(&Info.questions/1)
    |> Enum.flat_map(&judged_property/1)
  end

  @doc "The host-declared crisp fact-schema attributes (the v0 slice's synthetic demo schema)."
  @spec crisp() :: [Property.t()]
  def crisp do
    [
      %Property{
        name: "city",
        kind: :crisp,
        type: :string,
        description: "Demo crisp attribute: the vendor's service city."
      },
      %Property{
        name: "licence_current",
        kind: :crisp,
        type: :boolean,
        description: "Demo crisp attribute: the licence is current."
      },
      %Property{
        name: "revenue",
        kind: :crisp,
        type: :integer,
        description: "Demo crisp attribute: annual revenue."
      },
      %Property{
        name: "hourly_rate",
        kind: :crisp,
        type: :number,
        description: "Demo crisp attribute: hourly billing rate."
      }
    ]
  end

  @doc "One derived status field per judged predicate (S1-57 §6's frozen enum)."
  @spec derived() :: [Property.t()]
  def derived do
    Enum.map(judged(), fn property ->
      %Property{
        name: property.name <> ".status",
        kind: :status,
        type: :status,
        enum: status_words(),
        description:
          "Membership status of #{property.name} (the unknown partition's explicit spelling)."
      }
    end)
  end

  @doc "The frozen interchange status words (S1-57 §6)."
  @spec status_words() :: [String.t()]
  def status_words, do: @status_words

  @doc "Finds one declared property by exact name, or `nil`."
  @spec fetch(String.t()) :: Property.t() | nil
  def fetch(name) when is_binary(name) do
    Enum.find(all(), &(&1.name == name))
  end

  @doc """
  The canonical digest of the vocabulary as data. Stored on each proposal
  version: a run re-validates the stored document against the CURRENT
  vocabulary, so a declaration change between edit and run is a refusal,
  never a drift.
  """
  @spec digest() :: String.t()
  def digest do
    Enum.map(all(), fn %Property{} = p ->
      %{
        "name" => p.name,
        "kind" => to_string(p.kind),
        "type" => to_string(p.type),
        "enum" => p.enum
      }
    end)
    |> AshJudgments.Registry.Canonical.digest()
  end

  defp subject_resources do
    Application.get_env(:ash_enterprise, :system_one_subject_resources, [])
  end

  # Extraction-typed questions are refused at this surface (composite
  # values are not Basic-CQL2 scalars): they contribute NO property, and a
  # document referencing one is a ghost-property refusal.
  defp judged_property(%{type: AshJudgments.Evaluate.Extraction}), do: []

  defp judged_property(question) do
    [
      %Property{
        name: question.question_id,
        kind: :judged,
        type: judged_type(question.type),
        enum: judged_enum(question),
        description: judged_description(question)
      }
    ]
  end

  defp judged_type(AshAi.Evaluate.Noul), do: :boolean
  defp judged_type(AshAi.Evaluate.Choice), do: :string
  defp judged_type(AshAi.Evaluate.Score), do: :integer

  defp judged_enum(%{type: AshAi.Evaluate.Choice} = question) do
    Enum.map(question.options, &word/1)
  end

  defp judged_enum(_question), do: nil

  defp judged_description(%{type: AshAi.Evaluate.Choice} = question) do
    "Judged predicate (choice): " <> word_instructions(question)
  end

  defp judged_description(question), do: "Judged predicate: " <> word_instructions(question)

  defp word_instructions(question) when is_binary(question.instructions),
    do: question.instructions

  defp word_instructions(question), do: inspect(question.instructions)

  defp word(word) when is_atom(word), do: Atom.to_string(word)
  defp word(word) when is_binary(word), do: word
end
