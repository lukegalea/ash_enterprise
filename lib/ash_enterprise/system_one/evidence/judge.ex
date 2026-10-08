defmodule AshEnterprise.SystemOne.Evidence.Judge do
  @moduledoc """
  The judge seam: the orchestrator's only path to the instrument — the
  registry's generated judge actions, driven through the same
  `AshJudgments.Registry.Judge.judge_and_record/5` the BPMN signals action
  uses, so the profile resolution (pin, region, residency), the cache
  modes and the recorder all run exactly as any other judged question.

  Every call records ledger observations (one per answer; a matrix batch
  is one request with one observation per runtime question, RFC §5.1) and
  returns the observation ids — the packet's join to the ledger rows. The
  answers themselves are never copied anywhere: the packet references.

  ## The packet narrowing

  `source_enum` narrowing is enforced at this seam: after each batch
  decodes, every answer's `source_ids` is checked against the batch's
  packet candidates. A citation outside the packet cannot decode into the
  pipeline — the decode-side complement of
  `AshJudgments.Evaluate.Evidence.output_schema/1`'s per-call narrowing
  (the declared question carries no per-run enum; the packet arrives per
  run, so the boundary check runs per batch and REFUSES — reject, never
  repair).
  """

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.SystemOne
  alias AshJudgments.Registry.Info
  alias AshJudgments.Registry.Judge, as: RegistryJudge

  @doc """
  Judges `fresh_candidate_ids` (the batch's runtime questions) narrowed to
  `packet_candidates`, in chunks of at most the configured per-call cap.
  Returns `{:ok, answers, refs}` where `refs` is
  `[%{observation_id:, question_hash:}]` in answer order — AC-5's no-loss
  guarantee is structural: every candidate produces exactly one runtime
  question and one observation, across as many instrument calls as the cap
  requires.
  """
  def matrix_batch(opts, atoms, fresh_candidate_ids, packet_candidates) do
    case fresh_candidate_ids do
      [] ->
        {:ok, [], []}

      ids ->
        judge_chunks(opts, atoms, Enum.chunk_every(ids, per_call_cap(opts)), packet_candidates)
    end
  end

  defp per_call_cap(opts) do
    keyword(
      opts,
      :max_questions_per_call,
      AshEnterprise.SystemOne.Evidence.max_questions_per_call()
    )
  end

  defp judge_chunks(opts, atoms, chunks, packet_candidates) do
    texts = atom_texts(atoms)
    Enum.reduce_while(chunks, {:ok, [], []}, &judge_chunk(&1, &2, opts, texts, packet_candidates))
  end

  defp judge_chunk(chunk, {:ok, answers, refs}, opts, texts, packet_candidates) do
    case matrix_call(opts, chunk, texts, packet_candidates) do
      {:ok, chunk_answers, chunk_refs} ->
        {:cont, {:ok, answers ++ chunk_answers, refs ++ chunk_refs}}

      {:error, error} ->
        {:halt, {:error, error}}
    end
  end

  defp judge_chunk(_chunk, {:error, error}, _opts, _texts, _packet_candidates) do
    {:halt, {:error, error}}
  end

  @doc """
  One single-question judge call (`question_key` names the opt carrying the
  question's name: `:localisation_question` or `:existence_question`).
  Returns `{:ok, answer, %{observation_id:, question_hash:}}`.
  """
  def single(opts, question_key, state_args) do
    resource = Keyword.fetch!(opts, :resource)
    name = Keyword.fetch!(opts, question_key)
    question = Info.question(resource, name)

    judge_input =
      resource
      |> Ash.ActionInput.for_action(judge_action(name), %{"input" => state_args})
      |> Map.replace!(:context, judge_context(opts))

    ctx = judge_context(opts)

    case RegistryJudge.judge_and_record(question, judge_input, ctx, ctx, question: name) do
      {:ok, answer, [observation_id]} ->
        {:ok, answer, %{observation_id: observation_id, question_hash: question.question_hash}}

      {:error, error, _partial} ->
        {:error, error}
    end
  end

  ## One matrix instrument call: one runtime question per candidate, one
  ## observation per answer, then the packet narrowing check.

  defp matrix_call(opts, candidate_ids, texts, packet_candidates) do
    resource = Keyword.fetch!(opts, :resource)
    name = Keyword.fetch!(opts, :question)
    question = Info.question(resource, name)
    claim = Keyword.fetch!(opts, :claim)

    state_args = %{
      "packet" => Map.new(candidate_ids, &{&1, texts[&1]}),
      "claim" => claim
    }

    runtime_questions = Enum.map(candidate_ids, &runtime_question(&1, question))

    judge_input =
      resource
      |> Ash.ActionInput.for_action(judge_action(name, "_matrix"), %{
        "input" => state_args,
        "questions" => runtime_questions
      })
      |> Map.replace!(:context, judge_context(opts, packet_candidates))

    ctx = judge_context(opts, packet_candidates)

    case RegistryJudge.judge_and_record(question, judge_input, ctx, ctx,
           question: name,
           matrix?: true
         ) do
      {:ok, answers, observation_ids} ->
        refs =
          Enum.map(observation_ids, &%{observation_id: &1, question_hash: question.question_hash})

        with :ok <- check_citations(answers, packet_candidates) do
          {:ok, answers, refs}
        end

      {:error, error, _partial} ->
        {:error, error}
    end
  end

  # The packet narrowing (see the moduledoc): a citation outside the
  # packet's candidates refuses the batch — the evidence it carried never
  # reaches a packet or an assertion.
  defp check_citations(answers, packet_candidates) do
    allowed = MapSet.new(packet_candidates)

    outside =
      answers
      |> Enum.flat_map(&(&1.source_ids || []))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(allowed, &1))

    if outside == [] do
      :ok
    else
      {:error, {:citation_outside_packet, outside}}
    end
  end

  # One runtime question per candidate: the candidate is named IN the
  # instructions (each candidate is its own wire question, RFC §5.1); the
  # state carries that batch's packet — the candidate texts the reply may
  # cite.
  defp runtime_question(candidate_id, question) do
    %{instructions: candidate_instructions(candidate_id, question.instructions)}
  end

  defp candidate_instructions(candidate_id, instructions) when is_binary(instructions) do
    "Candidate atom #{candidate_id}. #{instructions}"
  end

  defp candidate_instructions(candidate_id, instructions) do
    %{"candidate_atom_id" => candidate_id, "question" => instructions}
  end

  ## The judge context — built ONLY here, next to the judge call (the
  ## domain module owns the shape; the orchestrator threads attribution).

  defp judge_context(opts, packet_candidates \\ nil) do
    atom_ids = packet_candidates || []

    SystemOne.judge_context(
      tenant: Keyword.fetch!(opts, :tenant),
      correlation_id: keyword(opts, :correlation_id, Correlation.id()),
      judgments:
        %{
          subject: Keyword.get(opts, :subject),
          # §5.4: the packet's candidates ride every observation as the
          # atoms considered — the evidence-work path's input provenance.
          atom_ids: atom_ids,
          state_ref: %{
            "document_version_id" => Keyword.get(opts, :document_version_id),
            "atom_ids" => atom_ids
          },
          mode: Keyword.get(opts, :mode, :live)
        }
        |> Map.merge(Keyword.get(opts, :judgments) || %{})
    )
  end

  # The action names the registry generated for the declared question —
  # `String.to_existing_atom` is the safe spelling (law 10): the atoms
  # exist for every declared question, and an undeclared name fails loud
  # at the seam instead of minting an atom.
  defp judge_action(name, suffix \\ "") do
    String.to_existing_atom("judge_#{Atom.to_string(name)}#{suffix}")
  end

  defp atom_texts(atoms), do: Map.new(atoms, &{&1.id, &1.text})

  defp keyword(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> default
    end
  end
end
