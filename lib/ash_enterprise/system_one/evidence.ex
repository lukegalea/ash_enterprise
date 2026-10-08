defmodule AshEnterprise.SystemOne.Evidence do
  @moduledoc """
  The adjudication orchestrator — retrieval in, assertions out (AST-152;
  the AST-51b ticket; the evidence-packets design note §2.3).

  The pipeline owns what was PROPOSED; the banding→admission→materialiser
  chain owns what becomes truth (the v2 division, one layer up). Four
  steps, per §2.3:

    1. **Retrieve** (`AshEvidence.retrieve/3`, `persist?: true` — the
       candidate set is the search proof the packet cites; shape B skips
       retrieval: the whole document is the state).
    2. **Judge** — per-candidate `Evidence` questions through the
       registry's judge actions (shape A), or the whole-document shape: a
       tagged-id `Choice` localisation plus an existence `Noul` (shape B).
       Every answer is a ledger observation, recorded by the ordinary
       recorder under the caller's mode (law 2: the instrument is called
       before anything is written, and the write is pure recording).
    3. **Aggregate** — `AshEvidence.Assertions.Aggregation` composes the
       recorded marginals (contradiction dominates); the rule version
       rides the assertion.
    4. **Record** — the packet, then the assertion on the host's platform
       base (AshEvents-audited). The assertion create is INPUTS-ONLY:
       nothing instrument-shaped exists anywhere on it, so an AshEvents
       replay rebuilds the row byte-identically with zero model calls
       (AC-2). The evaluation row starts with the loop's COMPLETE
       bookkeeping — the package's `start` contract accepts
       `candidate_set_ids` and `expansion_steps`, and its closes are
       terminal — so the row is created once the loop is in the ledger
       (the ledger rows are the in-flight trace) and closes `:ok`/
       `:failed` exactly once. A failure after judging still records: the
       row starts with what the loop gathered and closes `:failed`.

  ## The proof-growth loop

  An `:insufficient` aggregate expands ONE retrieval step at a time, to
  the configured budget (`max_expansion_steps`): the re-retrieval adds the
  `:exception` framing and doubles `k` (the growth framing — looking where
  the first pass did not), the newly surfaced candidates are judged, and
  every step is recorded on the evaluation as
  `%{step, candidate_set_id, observation_ids}` — ids only. When the budget
  is exhausted and the aggregate is still `:insufficient`, the packet
  closes with `requires_expansion: true`: the thinness is reported, never
  hidden. An expansion step that surfaced nothing new is a spent step and
  stops the loop — re-running identical framings cannot grow the proof. A
  run with nothing to compose (no candidates, budget spent) records the
  flag and writes no assertion — there is nothing to assert.

  ## Call shapes

  * **A — `:candidate_local`**: per-candidate Evidence questions, batched
    through the matrix judge action in chunks of at most
    `max_questions_per_call` (the profile cap — transport plumbing, never
    a silent drop: every candidate is judged exactly once, AC-5). The
    pipeline refuses to assemble a packet from any answer citing an atom
    outside the packet's candidates — the
    `AshJudgments.Evaluate.Evidence` `source_enum` narrowing, enforced at
    the pipeline boundary (the per-call `output_schema/1` narrows the
    schema; this check is its decode-side complement), so a citation
    outside the packet cannot decode into an assertion.
  * **B — `:whole_document`**: the tagged document as one state; a
    declared `Choice` over the host's region tags localises the evidence,
    a declared `Noul` answers existence. Its assertion composes the
    existence answer into the evidence vocabulary deterministically
    (`supports := p`, `insufficient := 1 − p`). **Shape B cannot see
    contradiction** — it is the coarse triage shape for documents too
    large to packet per candidate; shape A is the compliance-grade shape.

  ## Config, and what it is not

  `config :ash_enterprise, :system_one_evidence` carries plumbing knobs
  and nothing else. None of them is a threshold in the law-4 sense: no
  admission decision reads them — bands stay versioned DMN band tables
  (the 51c handoff), and the assertion records whatever the evidence says.

  Runs as a service task (`AshEnterprise.SystemOne.Evidence.Worker`, the
  `:system_one` Oban queue — the banding-pipeline placement, d582f88) and
  never in a guard path, a policy check or a request (law 3).
  """

  @orchestrator_version "1"

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.SystemOne.Evidence.Judge
  alias AshEnterprise.SystemOne.EvidenceAssertion
  alias AshEvidence.Assertions.Aggregation
  alias AshEvidence.Assertions.Canonical
  alias AshJudgments.Registry.Info

  ## Config — transport plumbing, never policy (see the moduledoc).

  @doc "The configured per-call question cap (the profile cap, AC-5)."
  def max_questions_per_call do
    Keyword.get(config(), :max_questions_per_call, 5)
  end

  @doc "The configured proof-growth budget (expansion steps per run)."
  def max_expansion_steps do
    Keyword.get(config(), :max_expansion_steps, 1)
  end

  @doc "The orchestrator version — rides the question-set identity."
  def orchestrator_version, do: @orchestrator_version

  defp config, do: Application.get_env(:ash_enterprise, :system_one_evidence, [])

  defp retrieval_k, do: Keyword.get(config(), :retrieval_k, 10)

  ## Entry points

  @doc """
  Opens an adjudication: enqueues the worker. The job's args carry the
  claim and the asserting tenant (a uuid — attribution data, not content);
  job args are payload-class (the host's Oban retention prunes completed
  jobs), while the durable records keep digests and ids only. The
  evaluation row is created by the run itself, once the loop's bookkeeping
  is complete (the package's `start` contract — see the pipeline order in
  the moduledoc).
  """
  def open_adjudication(opts) do
    # Args carry the run's input set: the claim, the attribution, the
    # version, the shape, the admission handoff keys and the profile name.
    # Wiring — which declared questions adjudicate — never rides args.
    args = %{
      "claim" => Keyword.fetch!(opts, :claim),
      "tenant" => to_string(Keyword.fetch!(opts, :tenant)),
      "document_version_id" => to_string(Keyword.fetch!(opts, :document_version_id)),
      "call_shape" => to_string(Keyword.fetch!(opts, :call_shape)),
      "subject" => string_subject(Keyword.fetch!(opts, :subject)),
      "predicate" => Keyword.fetch!(opts, :predicate),
      "profile" => profile_name(Keyword.get(opts, :profile))
    }

    case args |> AshEnterprise.SystemOne.Evidence.Worker.new() |> Oban.insert() do
      {:ok, job} -> {:ok, %{job: job}}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Runs one adjudication synchronously — the worker's body, and the shape
  the tests drive. Required opts: `:tenant`, `:subject` (composite map),
  `:predicate`, `:claim`, `:document_version_id`, `:call_shape`
  (`:candidate_local | :whole_document`), `:resource` (the module
  declaring the questions). Shape A names `:question`; shape B names
  `:localisation_question` + `:existence_question` + `:regions` (the
  host's tag → atom-ids map — tagging is ingestion machinery, the
  orchestrator only reads it). Optional: `:actor` (default the system
  actor), `:mode`, `:correlation_id`, `:rule_ref`, `:profile`,
  `:max_expansion_steps`.

  Returns `{:ok, %{evaluation:, packet:, assertion:, disposition:,
  distribution:, observation_ids:, expansion_steps:, candidate_set_ids:}}`
  or `{:error, term}` — a failed run still closes its evaluation
  `:failed` (a failed run is a recorded run; the ParseRun terminal
  lifecycle).
  """
  def adjudicate(opts) do
    Correlation.with_correlation(Keyword.get(opts, :correlation_id) || Correlation.id(), fn ->
      run(opts)
    end)
  end

  @doc """
  The worker's body: the claim plus the run's wiring. The evaluation row is
  created by the run itself — with the loop's complete bookkeeping (the
  package's `start` contract) — so the worker carries the claim and the
  routing, never a row id.
  """
  def adjudicate(claim, opts) do
    opts = Keyword.put(opts, :claim, claim)

    Correlation.with_correlation(Keyword.get(opts, :correlation_id) || Correlation.id(), fn ->
      run(opts)
    end)
  end

  ## The pipeline (§2.3, one stage at a time)
  ##
  ## Shape A accumulates `rounds` (one per retrieval step) and flattens to
  ## the unified round at the end of the growth loop; shape B builds the
  ## unified round directly (no retrieval, no growth).

  # The pipeline order, fitted to the package's evaluation contract: the
  # loop runs first (every answer a ledger observation — the durable
  # in-flight trace), then the evaluation row starts WITH the loop's
  # complete bookkeeping (`start` accepts candidate_set_ids and
  # expansion_steps; its no-input closes are terminal), then the packet,
  # then the assertion, then the row closes. A failure AFTER judging still
  # records: the row starts with whatever the loop gathered and closes
  # `:failed` — a failed run is a recorded run.
  defp judge_loop(opts) do
    with {:ok, atoms} <- version_atoms(Keyword.fetch!(opts, :document_version_id)),
         {:ok, state} <- judge_round(opts, atoms, Keyword.fetch!(opts, :call_shape)) do
      {:ok, grow(opts, atoms, state)}
    else
      {:error, error, state} -> {:error, error, state}
      {:error, error} -> {:error, error, nil}
    end
  end

  defp run(opts) do
    case judge_loop(opts) do
      {:ok, round} ->
        with {:ok, evaluation} <- start_evaluation(opts, round),
             {:ok, packet} <- assemble_packet(evaluation, round) do
          close(evaluation, opts, round, packet)
        else
          {:error, error} -> fail_started(opts, round, error)
        end

      {:error, error, nil} ->
        # Nothing was judged — there is no run to record.
        {:error, error}

      {:error, error, round} ->
        fail_started(opts, round, error)
    end
  end

  ## The unified round — what the packet, the aggregation and the
  ## evaluation's expansion bookkeeping all read:
  ##
  ##   %{
  ##     candidate_set_ids: [uuid],
  ##     expansion_steps: [%{step:, candidate_set_id:, observation_ids:}],
  ##     candidate_ids: [atom id],       — ordered, unique; the packet's candidates
  ##     answers: [Evidence structs],    — shape B carries the existence answer
  ##     observation_refs: [%{observation_id:, question_hash:}],
  ##     extra_observation_ids: [uuid],  — shape B's localisation row
  ##     joins: %{atom id => %{observation_id, question_hash}},
  ##     selected: [atom id],
  ##     limiting: [atom id],
  ##     aggregation_observations: [%{value:, probabilities:}]
  ##   }

  ## Shape A — retrieval, batched per-candidate judging, proof growth

  defp judge_round(opts, atoms, :candidate_local) do
    version_id = Keyword.fetch!(opts, :document_version_id)
    claim = Keyword.fetch!(opts, :claim)

    # Competing hypotheses from the first pass (retrieving for support
    # only manufactures false supports); the candidate set is the packet's
    # proof-of-search.
    initial_opts = [
      hypotheses: [:supports, :contradicts],
      k: retrieval_k(),
      persist?: true
    ]

    with {:ok, result} <- AshEvidence.retrieve(version_id, claim, initial_opts) do
      judge_step(opts, atoms, result, 0, [], [])
    else
      {:error, error, state} -> {:error, error, state}
      {:error, error} -> {:error, error, nil}
    end
  end

  ## Shape B — tagged localisation Choice + existence Noul

  defp judge_round(opts, atoms, :whole_document) do
    claim = Keyword.fetch!(opts, :claim)
    regions = Keyword.fetch!(opts, :regions)
    document = tagged_document(atoms, regions)
    state_args = %{"document" => document, "claim" => claim}

    with {:ok, localisation, localisation_ref} <-
           Judge.single(opts, :localisation_question, state_args),
         {:ok, existence, existence_ref} <-
           Judge.single(opts, :existence_question, state_args) do
      candidate_ids = Enum.map(atoms, & &1.id)

      selected =
        case value_atom(localisation.value) do
          nil -> []
          tag -> Enum.filter(Map.get(regions, tag, []), &(&1 in candidate_ids))
        end

      # The whole-document shape's per-atom join: the atoms the
      # localisation NAMED were adjudicated by the Choice observation; the
      # rest ride the existence observation (what it covered: the document
      # as a whole). Ids and hashes only — never copied answers.
      joins =
        Map.new(candidate_ids, fn id ->
          ref = if id in selected, do: localisation_ref, else: existence_ref

          {id, %{"observation_id" => ref.observation_id, "question_hash" => ref.question_hash}}
        end)

      # The existence answer composes into the evidence vocabulary
      # deterministically (see the moduledoc: shape B cannot see
      # contradiction). A missing probability composes as no evidence.
      p =
        case existence.probability do
          nil -> 0.0
          p -> p * 1.0
        end

      disposition = if p >= 0.5, do: :supports, else: :insufficient

      {:ok,
       %{
         candidate_set_ids: [],
         expansion_steps: [],
         candidate_ids: candidate_ids,
         answers: [existence],
         observation_refs: [existence_ref],
         extra_observation_ids: [localisation_ref.observation_id],
         joins: joins,
         selected: selected,
         limiting: [],
         aggregation_observations: [
           %{value: disposition, probabilities: %{"supports" => p, "insufficient" => 1 - p}}
         ]
       }}
    else
      # A failed shape-B judgment: the recorded observation(s) ride the
      # ledger; the run row records only completed loops.
      {:error, error} -> {:error, error, nil}
    end
  end

  # One judged retrieval step: the freshly surfaced candidates go through
  # the matrix judge action in capped batches; the step's proof and its
  # observation ids accumulate onto the evaluation's bookkeeping.
  defp judge_step(opts, atoms, result, step, rounds, steps) do
    with :ok <- check_candidates(result, atoms) do
      packet_candidates = Enum.map(result.candidates, & &1.atom_id)
      judged = rounds |> Enum.flat_map(& &1.judged_ids)
      fresh = Enum.reject(packet_candidates, &(&1 in judged))

      case Judge.matrix_batch(opts, atoms, fresh, packet_candidates) do
        {:ok, answers, refs} ->
          round = %{
            candidate_set_id: result.candidate_set_id,
            candidate_ids: packet_candidates,
            judged_ids: fresh,
            answers: answers,
            refs: refs
          }

          # The initial retrieval is not an expansion — it is cited via
          # candidate_set_ids; expansion_steps records the GROWTH steps.
          step_record =
            if step == 0 do
              nil
            else
              %{
                step: step,
                candidate_set_id: result.candidate_set_id,
                observation_ids: Enum.map(refs, & &1.observation_id)
              }
            end

          rounds = rounds ++ [round]
          steps = if step_record, do: steps ++ [step_record], else: steps

          {:ok,
           %{
             opts: opts,
             rounds: rounds,
             steps: steps,
             candidate_set_ids: Enum.map(rounds, & &1.candidate_set_id)
           }}

        {:error, error} ->
          # The batch refused (a citation outside the packet): the run
          # fails with whatever earlier rounds gathered — those rows are
          # recorded, so the failed run records too.
          {:error, error,
           %{
             opts: opts,
             rounds: rounds,
             steps: steps,
             candidate_set_ids: Enum.map(rounds, & &1.candidate_set_id)
           }}
      end
    else
      {:error, error} -> {:error, error, nil}
    end
  end

  # The proof-growth loop. Aggregates what is gathered so far; an
  # `:insufficient` verdict (and remaining budget) expands one retrieval
  # step. Everything re-aggregates over ALL answers — marginals composed
  # as marginals, never round-by-round maxima.
  defp grow(opts, atoms, state) do
    budget = Keyword.get(opts, :max_expansion_steps) || max_expansion_steps()
    do_grow(opts, atoms, state, budget)
  end

  defp do_grow(opts, _atoms, state, budget) when budget <= 0, do: finalise(opts, state)

  defp do_grow(opts, atoms, state, budget) do
    case Aggregation.aggregate(live_aggregation_observations(state)) do
      {:ok, %{disposition: :insufficient}} ->
        # Steps number the ROUNDS: the initial retrieval is round 0 (never
        # recorded as an expansion), the first growth round is step 1.
        step = length(state.rounds)
        claim = Keyword.fetch!(opts, :claim)
        version_id = Keyword.fetch!(opts, :document_version_id)

        # The growth framing: the hypothesis the first pass did not run,
        # and a doubled k.
        growth_opts = [
          hypotheses: [:supports, :contradicts, :exception],
          k: retrieval_k() * 2,
          persist?: true
        ]

        case AshEvidence.retrieve(version_id, claim, growth_opts) do
          {:ok, result} ->
            case judge_step(opts, atoms, result, step, state.rounds, state.steps) do
              {:ok, grown} ->
                last = List.last(grown.rounds)

                # Nothing new surfaced: re-retrieving identical framings
                # cannot grow the proof — the budget stops here.
                if last.judged_ids == [] and length(grown.rounds) > 1 do
                  finalise(opts, grown)
                else
                  do_grow(opts, atoms, grown, budget - 1)
                end

              # A failed expansion keeps the evidence already gathered; the
              # packet closes with what the earlier rounds saw.
              {:error, _error, _partial} ->
                finalise(opts, state)
            end

          {:error, _error} ->
            finalise(opts, state)
        end

      {:ok, _aggregate} ->
        finalise(opts, state)

      {:error, _error} ->
        finalise(opts, state)
    end
  end

  defp value_atom(value) when is_atom(value), do: value

  defp value_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp value_atom(_other), do: nil

  ## Flattening — shape A's accumulated rounds to the unified round

  defp finalise(opts, %{rounds: [_ | _]} = state) do
    question = Info.question(Keyword.fetch!(opts, :resource), Keyword.fetch!(opts, :question))

    # Each round's judged candidates, answers and observation refs are
    # parallel lists (the matrix preserves order), so the flattened lists
    # stay aligned across rounds.
    judged_ids = Enum.flat_map(state.rounds, & &1.judged_ids)
    answers = Enum.flat_map(state.rounds, & &1.answers)
    refs = Enum.flat_map(state.rounds, & &1.refs)

    joins =
      judged_ids
      |> Enum.zip(refs)
      |> Map.new(fn {atom_id, ref} ->
        {atom_id,
         %{"observation_id" => ref.observation_id, "question_hash" => question.question_hash}}
      end)

    limiting =
      for {atom_id, answer} <- Enum.zip(judged_ids, answers),
          answer.value == :insufficient do
        atom_id
      end

    %{
      candidate_set_ids: state.candidate_set_ids,
      expansion_steps: state.steps,
      candidate_ids: state.rounds |> Enum.flat_map(& &1.candidate_ids) |> Enum.uniq(),
      answers: answers,
      observation_refs: refs,
      extra_observation_ids: [],
      joins: joins,
      selected: answers |> Enum.flat_map(&(&1.source_ids || [])) |> Enum.uniq(),
      limiting: limiting,
      aggregation_observations:
        Enum.map(answers, fn answer ->
          %{value: answer.value, probabilities: answer.probabilities}
        end)
    }
  end

  # Shape B's round arrives already flat.
  defp finalise(_opts, state), do: state

  # The growing state (rounds) has no aggregation field yet — build it;
  # the flat one does.
  defp live_aggregation_observations(%{aggregation_observations: obs}) when is_list(obs),
    do: obs

  defp live_aggregation_observations(%{rounds: rounds}) do
    rounds
    |> Enum.flat_map(& &1.answers)
    |> Enum.map(&%{value: &1.value, probabilities: &1.probabilities})
  end

  ## Packet assembly (ids and joins only — answers are never copied)

  defp assemble_packet(evaluation, round) do
    requires_expansion =
      case Aggregation.aggregate(round.aggregation_observations) do
        {:ok, %{disposition: :insufficient}} -> true
        {:ok, _aggregate} -> false
        # Nothing to compose: the proof stayed empty — report it.
        {:error, _} -> true
      end

    AshEvidence.Domain.assemble_packet(%{
      evaluation_id: evaluation.id,
      candidate_atom_ids: round.candidate_ids,
      candidate_observations: round.joins,
      selected_atom_ids: round.selected,
      limiting_atom_ids: Enum.uniq(round.limiting),
      missing_dimensions: [],
      requires_expansion: requires_expansion
    })
  end

  ## Close: aggregate → assertion → evaluation terminal state

  defp close(evaluation, opts, round, packet) do
    question_set_hash = evaluation.question_set_hash

    case Aggregation.aggregate(round.aggregation_observations) do
      {:ok, aggregate} ->
        case record_assertion(evaluation, opts, round, packet, aggregate, question_set_hash) do
          {:ok, assertion} ->
            with {:ok, evaluation} <- AshEvidence.Domain.mark_evaluation_ok(evaluation) do
              {:ok,
               %{
                 evaluation: evaluation,
                 packet: packet,
                 assertion: assertion,
                 disposition: aggregate.disposition,
                 distribution: aggregate.distribution,
                 observation_ids: observation_ids(round),
                 expansion_steps: round.expansion_steps,
                 candidate_set_ids: round.candidate_set_ids
               }}
            end

          {:error, error} ->
            fail(evaluation, error)
        end

      # Nothing to compose (retrieval found nothing, budget spent): the
      # packet recorded requires_expansion; there is nothing to assert.
      {:error, :no_observations} ->
        with {:ok, evaluation} <- AshEvidence.Domain.mark_evaluation_ok(evaluation) do
          {:ok,
           %{
             evaluation: evaluation,
             packet: packet,
             assertion: nil,
             disposition: nil,
             distribution: nil,
             observation_ids: observation_ids(round),
             expansion_steps: round.expansion_steps,
             candidate_set_ids: round.candidate_set_ids
           }}
        end

      {:error, error} ->
        fail(evaluation, error)
    end
  end

  defp observation_ids(round) do
    Enum.map(round.observation_refs, & &1.observation_id) ++ round.extra_observation_ids
  end

  # The assertion create — INPUTS ONLY. The aggregation ran above, in the
  # orchestrator; the create's only change derives `record_hash` from these
  # inputs (pure, replay-identical). Nothing here calls anything (AC-2).
  defp record_assertion(evaluation, opts, round, packet, aggregate, question_set_hash) do
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.get(opts, :actor, SystemActor.process())

    inputs = %{
      "id" => Ash.UUID.generate(),
      "packet_id" => packet.id,
      "evaluation_id" => evaluation.id,
      "disposition" => aggregate.disposition,
      "distribution" => aggregate.distribution,
      "aggregation_rule_version" => aggregate.rule_version,
      "observation_ids" => observation_ids(round),
      "subject" => string_subject(Keyword.fetch!(opts, :subject)),
      "predicate" => Keyword.fetch!(opts, :predicate),
      "subject_state_digest" => subject_state_digest(opts, round),
      "question_set_hash" => question_set_hash
    }

    case EvidenceAssertion
         |> Ash.Changeset.for_create(:record, inputs, actor: actor, tenant: tenant)
         |> Ash.create() do
      {:ok, assertion} -> {:ok, assertion}
      {:error, error} -> {:error, {:assertion_create_failed, error}}
    end
  end

  ## The evaluation row (the ParseRun pattern: pending → ok | failed, once)

  defp start_evaluation(opts, round) do
    inputs = %{
      "subject" => string_subject(Keyword.fetch!(opts, :subject)),
      "predicate" => Keyword.fetch!(opts, :predicate),
      "rule_ref" => Keyword.get(opts, :rule_ref),
      "document_version_id" => Keyword.fetch!(opts, :document_version_id),
      "question_set_hash" => question_set_hash(opts),
      "candidate_set_ids" => (round && Map.get(round, :candidate_set_ids)) || [],
      "expansion_steps" => (round && Map.get(round, :expansion_steps)) || [],
      "profile" => profile_name(Keyword.get(opts, :profile)),
      "call_shape" => Keyword.fetch!(opts, :call_shape)
    }

    AshEvidence.Domain.start_evaluation(inputs)
  end

  defp fail(evaluation, error) do
    _ = AshEvidence.Domain.mark_evaluation_failed(evaluation)
    {:error, error}
  end

  # A failure after judging: the row starts with the loop's bookkeeping and
  # closes :failed — the run is recorded, and the error returned.
  defp fail_started(opts, round, error) do
    case start_evaluation(opts, round) do
      {:ok, evaluation} ->
        fail(evaluation, error)

      {:error, record_error} ->
        {:error, {:record_failed, record_error, error}}
    end
  end

  ## Identity, digests, and small plumbing

  @doc """
  The question-set identity (law 6's field): the declared questions'
  hashes, the call shape, the profile and the orchestrator version — a
  canonical digest. A changed question, shape or orchestrator is a
  different question set.
  """
  def question_set_hash(opts) do
    resource = Keyword.fetch!(opts, :resource)
    call_shape = Keyword.fetch!(opts, :call_shape)

    names =
      case call_shape do
        :candidate_local -> [Keyword.fetch!(opts, :question)]
        :whole_document -> [opts[:localisation_question], opts[:existence_question]]
      end

    hashes =
      Enum.map(names, fn name ->
        name && Info.question(resource, name).question_hash
      end)

    Canonical.digest(%{
      "question_hashes" => hashes,
      "call_shape" => call_shape,
      "profile" => profile_name(Keyword.get(opts, :profile)),
      "orchestrator_version" => @orchestrator_version
    })
  end

  # The §7.4 freshness binding: the state the predicate was evaluated
  # against — the version, the packet's candidates, the growth steps taken.
  # A pure function of recorded ids, so a replay recomputes it identically.
  defp subject_state_digest(opts, round) do
    Canonical.digest(%{
      "document_version_id" => Keyword.fetch!(opts, :document_version_id),
      "candidate_atom_ids" => round.candidate_ids,
      "expansion_steps" => length(round.expansion_steps)
    })
  end

  defp version_atoms(version_id) do
    case AshEvidence.Domain.atoms_for_version(version_id) do
      {:ok, atoms} -> {:ok, Enum.map(atoms, &%{id: &1.id, seq: &1.seq, text: &1.text})}
      {:error, error} -> {:error, error}
    end
  end

  # Every candidate a retrieval surfaced must be an atom of THIS version:
  # a citation outside the version cannot decode into an assertion. (The
  # per-packet narrowing — citations within the run's candidate set — is
  # checked against each judge batch's answers in the Judge module.)
  defp check_candidates(result, atoms) do
    known = MapSet.new(atoms, & &1.id)

    unknown =
      result.candidates
      |> Enum.map(& &1.atom_id)
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.uniq()

    if unknown == [] do
      :ok
    else
      {:error, {:candidates_outside_version, unknown}}
    end
  end

  defp tagged_document(atoms, regions) do
    by_id = Map.new(atoms, &{&1.id, &1.text})

    regions
    |> Enum.sort_by(fn {_tag, ids} -> seq_of(List.first(ids), atoms) end)
    |> Enum.map_join("\n", fn {tag, ids} ->
      body = ids |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1) |> Enum.join(" ")

      "«#{tag}» #{body}"
    end)
  end

  defp seq_of(atom_id, atoms) do
    case Enum.find(atoms, &(&1.id == atom_id)) do
      nil -> 0
      atom -> atom.seq
    end
  end

  defp string_subject(%{} = subject) do
    %{
      "type" => to_string(subject[:type] || subject["type"]),
      "id" => to_string(subject[:id] || subject["id"])
    }
  end

  defp profile_name(name) when is_atom(name), do: Atom.to_string(name)
  defp profile_name(name) when is_binary(name), do: name
  defp profile_name(_resolver), do: "custom"
end
