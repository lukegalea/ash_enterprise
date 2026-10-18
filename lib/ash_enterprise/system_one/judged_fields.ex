defmodule AshEnterprise.SystemOne.JudgedFields do
  @moduledoc """
  Derived judgment fields on a host resource (S1-53; the PL-1 slice): for
  every question the resource declares in its `judgments do` registry, the
  resource gains fields that READ the facts table. Nothing is written per
  question; the registry is the only input.

      use AshEnterprise.Platform.Resource,
        domain: ...,
        extra_extensions: [AshAi, AshJudgments.Registry, AshOban, AshEnterprise.SystemOne.JudgedFields]

      judgments do
        question :task_actionable do
          ...
          state_projection AshEnterprise.SystemOne.JudgedFields.RecordState
          state_shape %{"title" => "string"}
        end
      end

  ## What a question gets

  For a question named `q`:

  - `q` — the **tri-state** membership, `true | false | nil`. `nil` is the
    unknown partition: no fact, an omitted admission, an open review, a
    stale or expired fact, or a fact below the reader's grade floor. It is
    never folded into either side (ADR 0048), and SQL's three-valued logic
    keeps it that way in filters: `not q` matches only admitted-out facts.
  - `q_status` — the frozen interchange word (S1-57 §6):
    `:admitted_true | :admitted_false | :review | :not_assessed | :stale`.
    An expired fact reads `:stale` (the facts filter compiler's mapping);
    `:review` stays in the vocabulary but is never produced, because an
    open review writes no fact.
  - `q_reason` — why the tri-state is `nil` (`AshJudgments.Query.status/4`'s
    reasons): `:no_fact | :below_grade | :stale | :expired`, or `nil` when
    the fact is admitted.

  All three are public expression calculations over the facts table
  (`AshEnterprise.SystemOne.Fact`) with `min_grade` (`:grant` by default,
  `:person` for a person-only floor) and `scope` (a map; a fact in a
  narrower scope serves a broader ask, as in `AshJudgments.Query`) as
  arguments. They compile into the subject's own SQL statement, so
  filtering or sorting by them is one query with no instrument anywhere in
  the path, and JSON:API, GraphQL and A2UI see them the way they see any
  other public calculation. The facts table's own read policy applies to
  the subquery: an actor who may not read facts reads every field as
  unknown, never more.

  ## Freshness

  The resource also gains `judgment_digests`, a map of
  `question_id => state digest`: the digest of the state the question's
  judge would see for the record as it is now. It is maintained in the
  record's own transaction on every create and update that touches a
  projection field (`MaintainDigests`), and a fact whose recorded
  `subject_state_digest` differs from it reads as stale. A question's
  projection fields are the keys of its declared `state_shape`, each of
  which must name an attribute of the resource (checked at compile time).

  The digests are the current pointer, kept on the record's row: ADR 0053
  (C2) lets a host periodize them, which this does not do, so a read at a
  past `as_of` still compares a fact against the record's digests as they
  are now.

  When a write makes an existing fact stale, the same transaction enqueues
  the resource's reassess trigger (an AshOban trigger the resource
  declares, running the generated `:reassess_judgments` action). A write
  that changes no projection field enqueues nothing.
  """

  @judged_fields %Spark.Dsl.Section{
    name: :judged_fields,
    describe: """
    Options for the derived judgment fields. Every option has a default, so
    the section is only needed to change one.
    """,
    schema: [
      subject_type: [
        type: :string,
        doc:
          "The `subject_type` the facts carry for this resource. Defaults to the resource module's name."
      ],
      reassess_trigger: [
        type: :atom,
        default: :reassess_judgments,
        doc:
          "The AshOban trigger enqueued when a write turns a fact stale. It must run the `:reassess_judgments` action."
      ],
      assess_limit: [
        type: :pos_integer,
        default: 25,
        doc: "The most reassessments one reassess job may run (the bound on instrument calls)."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@judged_fields],
    transformers: [AshEnterprise.SystemOne.JudgedFields.Transformer],
    verifiers: [AshEnterprise.SystemOne.JudgedFields.Verifier]

  alias AshJudgments.Registry.Canonical

  @digest_attribute :judgment_digests
  @reassess_action :reassess_judgments
  @status_words [:admitted_true, :admitted_false, :review, :not_assessed, :stale]
  @reasons [:no_fact, :below_grade, :stale, :expired]

  @doc "The attribute holding each question's current state digest."
  def digest_attribute, do: @digest_attribute

  @doc "The generated reassess action's name."
  def reassess_action, do: @reassess_action

  @doc "The status words, in the frozen interchange order (S1-57 §6)."
  def status_words, do: @status_words

  @doc "The reasons an unknown tri-state reads `nil`."
  def reasons, do: @reasons

  @doc """
  The judged fields of a resource: one map per declared question with its
  `:name`, `:question_id`, the `:question` itself, the `:projection` keys,
  and the generated field names (`:tri_state`, `:status`, `:reason`).
  """
  def fields(resource) do
    if Code.ensure_loaded?(resource) and function_exported?(resource, :spark_dsl_config, 0) do
      Spark.Dsl.Extension.get_persisted(resource, :judged_fields, [])
    else
      []
    end
  end

  @doc "The resource's `subject_type` on the facts table."
  def subject_type(resource) do
    Spark.Dsl.Extension.get_persisted(resource, :judged_subject_type)
  end

  @doc "The reassess trigger's name."
  def reassess_trigger(resource) do
    Spark.Dsl.Extension.get_opt(
      resource,
      [:judged_fields],
      :reassess_trigger,
      :reassess_judgments
    )
  end

  @doc "The most reassessments one reassess job may run."
  def assess_limit(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:judged_fields], :assess_limit, 25)
  end

  @doc "The composite subject a fact about `id` carries (the facts table's `subject`)."
  def subject(resource, id), do: %{"type" => subject_type(resource), "id" => to_string(id)}

  @doc "The facts resource the fields read: this host's facts table."
  def facts_resource, do: AshEnterprise.SystemOne.Fact

  @doc """
  The state the question's judge sees for a record, as the judge action's
  `input` map: each projection key with the record's value, JSON-shaped
  (the shape it has when it crosses the wire and when it is replayed).
  `get` reads one attribute (a record field, or a changeset attribute).
  """
  def state_input(field, get) when is_function(get, 1) do
    Map.new(field.projection, fn key -> {key, json_value(get.(String.to_existing_atom(key)))} end)
  end

  @doc """
  The digest of the state the judge would see for `state_input` — the same
  `Canonical.digest(Canonical.encode(state))` the registry's judge path
  records as the observation's `state_digest`, computed through the same
  projection, so a fact admitted from that observation is fresh exactly
  while the record's projection fields are unchanged.
  """
  def state_digest(resource, field, state_input) do
    input =
      Ash.ActionInput.for_action(resource, judge_action(field), %{"input" => state_input})

    field.question
    |> project(input)
    |> Canonical.encode()
    |> Canonical.digest()
  end

  @doc "The question's generated judge action."
  def judge_action(field), do: String.to_existing_atom("judge_#{field.name}")

  # The registry's projection dispatch (`AshJudgments.Registry.Judge`),
  # repeated here so the digest is computed exactly as the judge computes it.
  defp project(%{state_projection: nil}, input) do
    Map.new(input.arguments, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp project(%{state_projection: projection}, input) when is_function(projection, 2),
    do: projection.(input, input.context)

  defp project(%{state_projection: {m, f, a}}, input),
    do: apply(m, f, [input, input.context | a])

  defp project(%{state_projection: m}, input) when is_atom(m), do: m.project(input, input.context)

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp json_value(%Ash.CiString{} = value), do: to_string(value)
  defp json_value(value) when is_boolean(value) or is_nil(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: value
end
