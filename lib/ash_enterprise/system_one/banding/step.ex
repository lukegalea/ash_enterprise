defmodule AshEnterprise.SystemOne.Banding.Step do
  @moduledoc """
  The host banding step: judged answers → DMN inputs → band-table
  evaluation → banding record → admission routing (RFC v0 §7.1–§7.2;
  AST-92 host wiring).

  The order is the ledger's §6.1 discipline, one stage at a time:

  1. **Flatten** the recorded answers into the FEEL-ready input map
     (`AshJudgments.Bridge.Dmn.inputs/2` — decimal strings, explicit
     present markers, family/risk tier/jurisdiction envelope inputs).
  2. **Evaluate** through the host resolver seam — an arity-3
     `(family, tenant, inputs)` MFA or function following the
     `Process.DecisionResolver` pattern: the host resolves WHICH versioned
     band table runs (tenant-aware, ADR 0041) and evaluates it through
     `AshEnterprise.Decisions.evaluate/3`, returning the §7.1 band-table
     ref, the outputs, the POPULATED `matched_rule_ids` (from
     `Evaluation.matched_rule_ids`) and the evaluation row's id. Tests
     stub this seam; the default implementation is
     `AshEnterprise.SystemOne.Banding.Resolver`.
  3. **Refuse, or record.** `matched_rule_ids` empty is a refusal, not a
     result (ADR 0041): the step returns `{:refusal, ...}` and writes NO
     banding row — a band table that cannot say which row fired is not
     auditable. Otherwise the band contract is validated and the banding
     is RECORDED — every output an input (`band`, `fact_value` admit-only,
     `reason_code`, the ref, the evaluation id, the inputs map), nothing
     recomputed — as a system actor under the caller's tenant and
     correlation id (the ledger's AC-4 attribution pattern: the AshEvents
     event carries both).
  4. **Route the band** (the admission side; the materialiser's semantics
     are the package's — `AshJudgments.Facts.Materialiser.materialise/2` —
     this step only routes): `admit` materialises the fact (`fact_value`,
     grant grade, the banding id as admission provenance); `review`
     materialises nothing — the open review task reads as `unknown` by
     absence, and its conclusion arrives later as a verdict or admission;
     `omit` supersedes any current fact (the predicate goes back to
     `unknown`).

  Subject addressing is the caller's: `subject`, `predicate` (the judged
  question's `question_id`), optional `scope`, `subject_state_digest` and
  `valid_until` ride in opts onto every materialisation.
  """

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.Banding
  alias AshJudgments.Bridge.Dmn
  alias AshJudgments.Facts.Materialiser

  @default_resolver AshEnterprise.SystemOne.Banding.Resolver

  @doc """
  Bands one judged answer set and routes the band.

  `answers` is the `AshJudgments.Bridge.Dmn.inputs/2` answer list
  (`%{question:, answer:, observation_id:}`). Required opts: `:family`
  (string), `:tenant`, `:subject` (composite map), `:predicate`. Optional:
  `:risk_tier`, `:jurisdiction`, `:scope`, `:subject_state_digest`,
  `:valid_until`, `:mode` (`:live | :shadow`), `:correlation_id`,
  `:resolver` (default `AshEnterprise.SystemOne.Banding.Resolver`),
  `:facts_resource`, `:banding_id` (an idempotency key for the write).

  Returns `{:ok, %{banding:, band:, materialisation:}}`, or
  `{:refusal, %{reason:, matched_rule_ids:, band_table:}}` — no banding
  row written — or `{:error, term}`.
  """
  def band(answers, opts) when is_list(answers) do
    family = Keyword.fetch!(opts, :family)
    tenant = Keyword.fetch!(opts, :tenant)
    inputs = Dmn.inputs(answers, family: family, risk_tier: Keyword.get(opts, :risk_tier))
    resolver = Keyword.get(opts, :resolver, @default_resolver)

    with {:ok, evaluation} <- resolve_band_table(resolver, family, tenant, inputs),
         evaluation = normalise_evaluation(evaluation),
         :ok <- check_refusal(evaluation),
         :ok <- Dmn.validate_output(evaluation.outputs) do
      record(evaluation, answers, inputs, opts)
    end
  end

  # The frozen band contract compares ATOMS (`Bridge.Dmn.bands/0`), while a
  # DMN table's output cell arrives as a string — and a single-output table
  # arrives as the bare scalar itself (boxic unwraps it). Normalise both:
  # wrap the scalar into {"band" => value}, then the band to its atom (the
  # values are the contract's own frozen enum — never minted from arbitrary
  # input).
  defp normalise_evaluation(evaluation) do
    outputs =
      case evaluation.outputs do
        band when is_binary(band) -> %{"band" => band}
        outputs when is_map(outputs) -> outputs
        _outputs -> %{}
      end

    outputs =
      case outputs do
        %{"band" => band} when is_binary(band) ->
          Map.put(outputs, "band", String.to_existing_atom(band))

        outputs ->
          outputs
      end

    Map.put(evaluation, :outputs, outputs)
  end

  ## The resolver seam: arity-3 MFA or function, per the
  ## Process.DecisionResolver pattern.

  defp resolve_band_table(resolver, family, tenant, inputs) when is_atom(resolver),
    do: resolver.band_table(family, tenant, inputs)

  defp resolve_band_table({m, f, a}, family, tenant, inputs),
    do: apply(m, f, [family, tenant, inputs | a])

  defp resolve_band_table(resolver, family, tenant, inputs) when is_function(resolver, 3),
    do: resolver.(family, tenant, inputs)

  ## Refusal at the boundary: empty matched_rule_ids never becomes a row.

  defp check_refusal(evaluation) do
    if Dmn.refusal?(evaluation) do
      {:refusal,
       %{
         reason:
           "the band table could not say which row fired (matched_rule_ids empty, ADR 0041)",
         matched_rule_ids: [],
         band_table: Map.get(evaluation, :band_table)
       }}
    else
      :ok
    end
  end

  ## Record + route.

  defp record(evaluation, answers, inputs, opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.get(opts, :actor, SystemActor.process())
    correlation_id = Keyword.get(opts, :correlation_id) || Correlation.id()

    band = band_of(evaluation)

    with {:ok, banding} <-
           create_banding(evaluation, answers, inputs, band, opts, tenant, actor, correlation_id),
         {:ok, materialisation} <- route(band, evaluation, banding, opts) do
      {:ok, %{banding: banding, band: band, materialisation: materialisation}}
    end
  end

  defp create_banding(evaluation, answers, inputs, band, opts, tenant, actor, correlation_id) do
    observation_ids = Enum.map(answers, & &1.observation_id)

    version =
      evaluation.band_table["definition_version"] || evaluation.band_table[:definition_version]

    # boxic v0 band tables are single-output (the band). When the table
    # does not emit them, the step derives fact_value (the gated answer's
    # own collapsed value — the admit is a proposal FOR that answer) and
    # reason_code (band + definition version) — flagged for v1: compound
    # band-table outputs in boxic.
    fact_value = fact_value_of(evaluation) || (band == :admit && answer_value(answers)) || nil
    reason_code = output_of(evaluation, "reason_code") || "band_#{band}_v#{version}"

    inputs_map =
      %{
        observation_ids: observation_ids,
        band: band,
        reason_code: reason_code,
        matched_rule_ids: evaluation.matched_rule_ids,
        band_table: evaluation.band_table,
        decision_evaluation_id: evaluation.decision_evaluation_id,
        inputs: inputs,
        mode: Keyword.get(opts, :mode, :live),
        correlation_id: correlation_id
      }
      # Nil-only-when-absent fields are omitted, not passed as nil: an
      # explicit nil is an input the record contract rejects.
      |> maybe_put(:id, Keyword.get(opts, :banding_id))
      |> maybe_put(:fact_value, fact_value)

    Banding
    |> Ash.Changeset.for_create(:record, inputs_map, actor: actor, tenant: tenant)
    |> Ash.create()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp route(:review = band, evaluation, banding, opts) do
    # The materialiser writes nothing for a review — the open task reads
    # as unknown by absence. The verdict is returned so the caller's
    # review-task wiring can key on it.
    materialise(band, evaluation, banding, opts)
  end

  defp route(band, evaluation, banding, opts), do: materialise(band, evaluation, banding, opts)

  defp materialise(band, _evaluation, banding, opts) do
    fact_value = fact_value_of_banding(banding)

    decision = %{
      result: admission_result(band),
      subject: Keyword.fetch!(opts, :subject),
      predicate: Keyword.fetch!(opts, :predicate),
      value: fact_value,
      holds: holds(fact_value, Keyword.get(opts, :holds_value, true)),
      grade: :grant,
      scope: Keyword.get(opts, :scope),
      subject_state_digest: Keyword.get(opts, :subject_state_digest),
      valid_until: Keyword.get(opts, :valid_until),
      admission_id: banding.id
    }

    materialiser_opts = Keyword.take(opts, [:facts_resource])

    Materialiser.materialise(decision, materialiser_opts)
  end

  defp fact_value_of_banding(banding), do: banding.fact_value

  defp answer_value(answers) do
    answers
    |> Enum.map(&(&1.answer && (Map.get(&1.answer, :value) || Map.get(&1.answer, "value"))))
    |> Enum.find(&(!is_nil(&1)))
    |> case do
      nil -> nil
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end
  end

  # RFC §7.1 → §7.2 are different layers with different vocabularies: the
  # banding's frozen band (`admit | review | omit`) becomes the admission's
  # result (`admitted | review | omitted` — Q11's `omitted` is the
  # no-fact-written value; `unknown` stays an ash_rules outcome).
  defp admission_result(:admit), do: :admitted
  defp admission_result(:review), do: :review
  defp admission_result(:omit), do: :omitted

  # RFC §7.4: for a judged boolean-shaped predicate, `true` is *in* and
  # `false` is *out*. The predicate's declared holds value is a call-site
  # opt (default `true`) until declarations carry it.
  defp holds(value, holds_value), do: value == holds_value

  defp band_of(evaluation), do: band_value(evaluation.outputs, :band, "band")

  defp fact_value_of(evaluation),
    do: evaluation.outputs[:fact_value] || evaluation.outputs["fact_value"]

  defp output_of(evaluation, key),
    do: evaluation.outputs[key] || evaluation.outputs[String.to_existing_atom(key)]

  defp band_value(outputs, atom_key, string_key) do
    value = outputs[atom_key] || outputs[string_key]

    case value do
      nil -> nil
      band when is_atom(band) -> band
      band when is_binary(band) -> String.to_existing_atom(band)
    end
  end
end
