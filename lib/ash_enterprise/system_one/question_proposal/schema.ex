defmodule AshEnterprise.SystemOne.QuestionProposal.Schema do
  @moduledoc """
  The decode contract for policy-to-question proposals (ADR 0046), and the
  vocabulary pass that finishes what JSON Schema cannot say.

  The JSON Schema at `priv/system_one/question_proposal.schema.json` is
  built at compile time and validated with JSV, exactly like the frozen
  judgment-record validator. Its derivation is documented in the file:
  the registry's own constraints, mirrored as data (`AshJudgments.Registry.Dsl`'s
  answer types; the options rules; atom-safe `name`/`family` because they
  become Spark identifiers), plus the ADR's non-negotiables — no confidence
  field, abstentions are the registry's job, `version` and `profile` are
  never model-provided.

  Decode-where-possible, validate-always: the wire schema is what the model
  decodes under; the cross-field rules JSON Schema cannot express (criteria
  keys must be exactly the options; `pii: minimised` requires a state
  shape) and the per-call narrowing the wire cannot carry (the profile is
  the caller's choice, not the model's) run here, after decode. A failure
  at either layer is a readable refusal — the raw output is retained on the
  proposal record for inspection, never best-effort parsed.
  """

  @schema_path Path.expand(
                 Path.join([
                   "..",
                   "..",
                   "..",
                   "..",
                   "priv",
                   "system_one",
                   "question_proposal.schema.json"
                 ]),
                 __DIR__
               )

  # Law 16: the schema is read at compile time, so an edit to it must
  # recompile this module.
  @external_resource @schema_path

  @schema_json File.read!(@schema_path)
  @schema Jason.decode!(@schema_json)
  @root JSV.build!(@schema)

  @answer_types %{
    "noul" => AshAi.Evaluate.Noul,
    "choice" => AshAi.Evaluate.Choice,
    "score" => AshAi.Evaluate.Score
  }

  @doc "Absolute path of the wire schema."
  @spec schema_path() :: String.t()
  def schema_path, do: @schema_path

  @doc "The decoded wire schema (draft 2020-12), as a string-keyed map."
  @spec schema() :: map()
  def schema, do: @schema

  @doc """
  The registry's shipped answer types, as the wire words map to the
  modules — the derivation source for the schema's `answer_type` enum.
  """
  @spec answer_types() :: %{String.t() => module()}
  def answer_types, do: @answer_types

  @doc """
  Schema-validates decoded model output (the whole `{proposals: [...]}`
  document). Returns `:ok` or a readable refusal.
  """
  @spec validate_document(term()) :: :ok | {:error, String.t()}
  def validate_document(document) do
    case JSV.validate(document, @root) do
      {:ok, _} -> :ok
      {:error, %JSV.ValidationError{} = error} -> {:error, Exception.message(error)}
    end
  end

  @doc """
  The vocabulary pass over one schema-valid proposal: the cross-field rules
  the wire cannot carry. Returns the normalised declaration map — the exact
  identity inputs of RFC §3.2 — or a readable refusal.

  Everything stays a STRING on purpose: a proposal's names, options and
  families are NEW vocabulary, and minting atoms from model output is the
  one thing this mechanism must never do (the atom table never GCs). The
  registry's canonical encoder renders atoms as their strings, so a hash
  computed over these strings is byte-identical to the hash of the declared
  question whose DSL brings the atoms into existence. The instrument
  profile is deliberately absent: it is the caller's choice, recorded on
  the proposal, never the model's.
  """
  @spec normalise(term()) :: {:ok, map()} | {:error, String.t()}
  def normalise(entry) when is_map(entry) do
    with :ok <- check_option_vocabulary(entry),
         :ok <- check_criteria(entry),
         :ok <- check_pii(entry) do
      {:ok,
       %{
         clause_ref: entry["clause_ref"],
         name: entry["name"],
         answer_type: @answer_types[entry["answer_type"]],
         options: option_words(entry),
         instructions: entry["instructions"],
         criteria: entry["criteria"],
         family: entry["family"],
         state_shape: Map.get(entry, "state_shape"),
         pii: Map.get(entry, "pii", "none"),
         version: 1
       }}
    end
  end

  @doc """
  The abstention the registry appends to a Choice's options (law 7; the
  DSL's `abstain_option` default). Proposals are hashed with it appended,
  exactly as the registry derives a declared Choice's options — the model
  never emits it (ADR 0046 point 5), the mechanism adds it.
  """
  @spec abstain_option() :: String.t()
  def abstain_option, do: "insufficient"

  @doc """
  The question hash of one normalised declaration — the registry's own
  `Canonical.question_hash/1`, so the confirmed proposal's identity is the
  identity the declared question carries at version 1.
  """
  @spec question_hash(map()) :: String.t()
  def question_hash(declaration) do
    AshJudgments.Registry.Canonical.question_hash(%{
      answer_type: declaration.answer_type,
      instructions: declaration.instructions,
      options: declaration.options,
      criteria: declaration.criteria,
      state_contract: AshJudgments.Registry.Canonical.state_contract(declaration.state_shape),
      version: declaration.version
    })
  end

  defp option_words(%{"answer_type" => "noul"}), do: [true, false]

  defp option_words(%{"answer_type" => "choice", "options" => options}) do
    options ++ [abstain_option()]
  end

  defp option_words(%{"options" => options}), do: options

  # The option vocabulary is the proposal's OWN payload — a new question
  # defines new words — but it must be coherent: atom-safe words the schema
  # already checked, no duplicates among them (the schema's uniqueItems
  # covers raw strings; the true/false fold re-checks), and the criteria
  # keys must be exactly the options, because per-option criteria that name
  # words the question does not ask over would be a ghost vocabulary.
  defp check_option_vocabulary(%{"answer_type" => "noul"} = entry) do
    if Map.has_key?(entry, "options") do
      {:error, "a noul proposal carries options, but a noul's options are derived [true, false]"}
    else
      :ok
    end
  end

  defp check_option_vocabulary(%{"options" => options}) do
    if Enum.uniq(options) == options do
      :ok
    else
      {:error, "duplicate options: #{inspect(options)}"}
    end
  end

  defp check_option_vocabulary(_entry), do: :ok

  defp check_criteria(%{"criteria" => criteria} = entry) when is_map(criteria) do
    keys =
      criteria
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    expected =
      entry
      |> Map.get("options", ["true", "false"])
      |> Enum.sort()

    if keys == expected do
      :ok
    else
      {:error,
       "criteria keys #{inspect(keys)} do not match the option vocabulary #{inspect(expected)}"}
    end
  end

  defp check_criteria(_entry), do: :ok

  defp check_pii(%{"pii" => "minimised"} = entry) do
    case Map.get(entry, "state_shape") do
      nil ->
        {:error,
         "pii: minimised requires a state_shape (a projection minimises what the model sees)"}

      _shape ->
        :ok
    end
  end

  defp check_pii(_entry), do: :ok
end
