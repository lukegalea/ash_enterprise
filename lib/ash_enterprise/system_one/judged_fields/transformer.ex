defmodule AshEnterprise.SystemOne.JudgedFields.Transformer do
  @moduledoc """
  Generates the derived judgment fields from the question registry: per
  declared question, the tri-state, status and reason calculations; per
  resource, the `judgment_digests` attribute, the digest-maintaining change
  and the `:reassess_judgments` action. Runs after the registry's own
  transformer, which derives each question's identity and persists the
  list this reads.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshEnterprise.SystemOne.JudgedFields
  alias AshEnterprise.SystemOne.JudgedFields.Calculation
  alias AshEnterprise.SystemOne.JudgedFields.MaintainDigests
  alias AshEnterprise.SystemOne.JudgedFields.Reassess
  alias Spark.Dsl.Transformer

  # Sobelow reads `@sobelow_skip` out of the source AST; persisting it is what
  # keeps `--warnings-as-errors` from calling it unused (see audit/export.ex).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @impl true
  def after?(AshJudgments.Registry.Transformers), do: true
  def after?(_), do: false

  @impl true
  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueFieldNames), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(AshOban.Transformers.SetDefaults), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    questions = Transformer.get_persisted(dsl_state, :questions, [])

    subject_type =
      Transformer.get_option(dsl_state, [:judged_fields], :subject_type) || inspect(module)

    fields = Enum.map(questions, &field/1)

    dsl_state
    |> Transformer.persist(:judged_fields, fields)
    |> Transformer.persist(:judged_subject_type, subject_type)
    |> add_digest_attribute()
    |> add_calculations(fields, subject_type)
    |> add_change()
    |> add_reassess_action()
  end

  # The field names are minted at compile time, inside this transformer, from
  # question names declared in the resource's DSL: never from runtime input,
  # and bounded by the declarations. Skipped by name here so that any other
  # atom interpolation in this module is still reported.
  @sobelow_skip ["DOS.BinToAtom"]
  defp field(question) do
    %{
      name: question.name,
      question_id: question.question_id,
      question: question,
      projection: projection(question.state_shape),
      tri_state: question.name,
      status: :"#{question.name}_status",
      reason: :"#{question.name}_reason"
    }
  end

  defp projection(shape) when is_map(shape), do: shape |> Map.keys() |> Enum.map(&to_string/1)
  defp projection(_shape), do: []

  defp add_digest_attribute(dsl_state) do
    {:ok, dsl_state} =
      Builder.add_new_attribute(dsl_state, JudgedFields.digest_attribute(), :map,
        public?: false,
        writable?: false,
        allow_nil?: true,
        description:
          "Each declared question's current state digest (question_id => digest): what a fact's subject_state_digest is compared against to read stale."
      )

    dsl_state
  end

  defp add_calculations(dsl_state, fields, subject_type) do
    Enum.reduce(fields, dsl_state, fn field, dsl_state ->
      opts = [question_id: field.question_id, subject_type: subject_type]

      dsl_state
      |> calculation(field.tri_state, :boolean, {Calculation, [mode: :tri_state] ++ opts},
        description:
          "Judged predicate #{field.question_id}: true (admitted in), false (admitted out), or nil (unknown — see #{field.reason})."
      )
      |> calculation(field.status, :atom, {Calculation, [mode: :status] ++ opts},
        constraints: [one_of: JudgedFields.status_words()],
        allow_nil?: false,
        description: "Membership status of #{field.question_id} (S1-57 §6 interchange words)."
      )
      |> calculation(field.reason, :atom, {Calculation, [mode: :reason] ++ opts},
        constraints: [one_of: JudgedFields.reasons()],
        description: "Why #{field.question_id} reads unknown; nil when a fact is admitted."
      )
    end)
  end

  defp calculation(dsl_state, name, type, impl, opts) do
    {:ok, dsl_state} =
      Builder.add_new_calculation(
        dsl_state,
        name,
        type,
        impl,
        Keyword.merge(
          [
            public?: true,
            arguments: [
              Builder.build_calculation_argument(:min_grade, :atom,
                allow_nil?: false,
                default: :grant,
                constraints: [one_of: [:grant, :person]]
              ),
              Builder.build_calculation_argument(:scope, :map, allow_nil?: true, default: nil)
            ]
          ],
          opts
        )
      )

    dsl_state
  end

  defp add_change(dsl_state) do
    {:ok, dsl_state} =
      Builder.add_change(dsl_state, {MaintainDigests, []}, on: [:create, :update])

    dsl_state
  end

  defp add_reassess_action(dsl_state) do
    {:ok, dsl_state} =
      Builder.add_new_action(dsl_state, :action, JudgedFields.reassess_action(),
        description: """
        Reassesses this record's stale or expired judged facts: selects them
        through `AshJudgments.Query.assess/4` (bounded by the resource's
        assess limit) and hands each to the configured assessor. Run by the
        resource's reassess trigger; never in a read.
        """,
        returns: :map,
        run: {Reassess, []},
        arguments: [
          Builder.build_action_argument(:primary_key, :map, allow_nil?: false, public?: true)
        ]
      )

    {:ok, dsl_state}
  end
end
