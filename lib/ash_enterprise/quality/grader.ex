defmodule AshEnterprise.Quality.Grader do
  @moduledoc """
  Grades agent replies (`AshEnterprise.Quality.AgentReply`) against the
  `agent_reply_style` questions: assess, judge, admit (S1-93).

  1. **Assess.** For each reply and each question asked of it
     (`AshEnterprise.Quality.Questions.for_reply/1`), the facts table is
     read against the reply's current digest
     (`AshJudgments.Query.status/4`). A pair with a current fact is done;
     one without (`:no_fact`, `:stale`, `:expired`) is pending. Nothing
     here calls a model.
  2. **Judge.** Each pending pair goes to the question's generated judge
     action, through the host judge context
     (`AshEnterprise.SystemOne.judge_context/1`, with the projected state
     as `judged_state:` so the ledger seals the text the model judged,
     under the reply's erasure scope) and the in-zone transport
     (`AshEnterprise.SystemOne.DecisionWire`). The answer is recorded in
     the judgment ledger under the reply's subject term.
  3. **Admit.** The recorded answer goes through the host banding step
     (`AshEnterprise.SystemOne.Banding.Step.band/2`): the family's band
     table decides admit, review or omit, and the materialiser writes the
     fact with the reply's digest.

  What is not admitted reads `unknown` in `AshEnterprise.Quality.Gate`:

    * a family with no published band table admits nothing: the answer
      stays in the ledger, the step returns the resolver's error;
    * a review-band answer writes no fact until a person records a verdict
      on it;
    * a model error records nothing in the ledger and admits nothing: the
      entry's `result` is the judge's `{:error, _}`, its `observation_id`
      is nil, and the failure is logged by reply id and question (never the
      text).

  ## Why this duplicates `AshEnterprise.Standards.Standing`

  The judge-and-admit sequence is the same as the standards standing
  job's. `Standing` is compiled only with `ash_agent_tools` and delegates
  its scan to `AshAgentTools.CodeSubjects.Standing`, which is tied to code
  units (paths, chunking, candidate selection). A reply has none of that,
  so the sequence is copied here rather than bent there. A change to one
  is a change to look for in the other.

  ## Evaluation replies only

  Only replies named by an evaluation run's case
  (`"agent_reply:<run_id>/<case_id>/<epoch>"`) are graded: those are the
  replies the synthetic evaluation tenant produces (ADR 0058). A reply
  named by its turn alone (`"assistant_turn:<turn_id>"`) raises an
  `ArgumentError` before anything is judged.

  The guard is the reply's name, not the tenant: no tenant is marked as
  the evaluation tenant yet, so there is nothing to check `:tenant`
  against. A caller that names a live turn's reply as an evaluation case
  is not stopped here; the evaluation run that mints those names is.

  ## The instrument identity is required

  Every judgment records the model version, model digest and runtime
  version it was answered by, and a person's verdict on it feeds the
  calibration slot those three key. `grade/2` and `judge_and_admit/3`
  raise an `ArgumentError` before anything is judged unless `:instrument`
  carries all three as strings, as the standards standing job refuses to
  judge with an instrument it cannot identify. An answer recorded without
  them takes a verdict but can never become a calibration sample.

  ## Options

    * `:tenant` (required): the evaluation tenant; the ledger and the
      bandings are held per tenant
    * `:actor`: default the `oban` system actor
    * `:questions`: the question names to ask (default all eight; a
      question is still asked only of the replies it applies to)
    * `:instrument` (required): the instrument identity recorded on each
      judgment, `%{model_version:, model_digest:, runtime_version:}`
    * `:judgments`: extra judge-context entries, such as a test transport
    * `:resolver`: the band-table resolver (the step's default otherwise)
    * `:mode`: `:live` by default
    * `:correlation_id`
    * `:facts_resource`: default `AshEnterprise.SystemOne.Fact`
  """

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.Questions
  alias AshEnterprise.SystemOne
  alias AshEnterprise.SystemOne.Banding
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshEnterprise.SystemOne.Judgment
  alias AshJudgments.Query

  require Ash.Query
  require Logger

  @facts AshEnterprise.SystemOne.Fact
  @evaluation_prefix "agent_reply:"

  @doc """
  The pending pairs: `[{reply, question_name, reason}]`, in reply order
  and then clause order, for every reply and question asked of it whose
  fact is missing, stale or expired. Raises unless every reply is an
  evaluation reply (see the moduledoc).
  """
  @spec assess([map()], keyword()) :: [{map(), atom(), atom()}]
  def assess(replies, opts \\ []) do
    ensure_evaluation_replies!(replies)
    digests = Quality.current_digests(replies)

    for reply <- replies,
        name <- names(opts),
        Questions.asked?(name, reply),
        {:unknown, reason} <- [status(reply, name, digests, opts)] do
      {reply, name, reason}
    end
  end

  @doc """
  Assesses, judges and admits (see the moduledoc). Returns one entry per
  pending pair: `%{reply_id, question, reason, observation_id, result}`,
  where `result` is the banding step's (`{:ok, %{band: ...}}`,
  `{:refusal, ...}` or `{:error, ...}`), the judge's `{:error, ...}`
  (with a nil `observation_id`), or `{:skipped, :already_banded}` (with
  the earlier observation's id) for a pair with no fact whose unchanged
  text this mode already judged and banded: a review waiting for a
  verdict, or an omit.
  """
  @spec grade([map()], keyword()) :: [map()]
  def grade(replies, opts) do
    unless Keyword.has_key?(opts, :tenant), do: raise(ArgumentError, "grade/2 needs :tenant")
    instrument!(opts)

    replies
    |> assess(opts)
    |> Enum.map(fn {reply, name, reason} ->
      {observation_id, result} =
        case already_banded(name, reply, reason, opts) do
          nil -> judge_and_admit(name, reply, opts)
          observation_id -> {observation_id, {:skipped, :already_banded}}
        end

      %{
        reply_id: reply.id,
        question: name,
        reason: reason,
        observation_id: observation_id,
        result: result
      }
    end)
  end

  @doc """
  One reply through one question's judge and the banding step: the answer
  is recorded under a fresh observation id, then banded. Returns
  `{observation_id, result}`; the id is nil when the judge failed.
  """
  @spec judge_and_admit(atom(), map(), keyword()) :: {Ash.UUID.t() | nil, term()}
  def judge_and_admit(name, reply, opts) do
    ensure_evaluation_replies!([reply])
    instrument = instrument!(opts)

    declared = Questions.declared(name)
    question = Questions.fetch!(name)
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.get(opts, :actor, SystemActor.oban())
    correlation_id = Keyword.get(opts, :correlation_id) || Correlation.id()
    mode = Keyword.get(opts, :mode, :live)
    observation_id = Ash.UUID.generate()
    term = Quality.subject_term(reply)

    input = Questions.judge_input(name, reply, actor: actor)

    context =
      SystemOne.judge_context(
        tenant: tenant,
        correlation_id: correlation_id,
        judgments:
          Map.merge(
            %{
              req_llm: SystemOne.DecisionWire,
              instrument: instrument,
              subject: %{type: term["type"], id: term["id"]},
              observation_id: observation_id,
              mode: mode
            },
            Keyword.get(opts, :judgments, %{})
          ),
        judged_state: Questions.judged_state(name, reply),
        judged_state_scope_id: Map.get(reply, :erasure_scope_id)
      )

    case Ash.run_action(input, context: context) do
      {:ok, answer} ->
        {observation_id,
         Step.band(
           [%{question: declared, answer: answer, observation_id: observation_id}],
           [
             family: to_string(declared.family),
             tenant: tenant,
             subject: term,
             predicate: declared.question_id,
             subject_state_digest: Quality.digest(reply),
             holds_value: question.holds_value,
             correlation_id: correlation_id,
             mode: mode,
             facts_resource: facts(opts)
           ] ++ Keyword.take(opts, [:resolver])
         )}

      {:error, error} ->
        Logger.warning(
          "agent reply #{reply.id}: the #{name} judge failed, nothing recorded or admitted: " <>
            reason_class(error)
        )

        {nil, {:error, error}}
    end
  end

  @doc "The facts-table predicate a question's facts are stored under."
  @spec predicate(atom()) :: String.t()
  def predicate(name), do: Questions.declared(name).question_id

  # A pair with no fact whose unchanged text was already judged and banded
  # in this mode is not judged again: a review waits for a person's
  # verdict, and an omit was the answer. An answer that was never banded
  # (no published band table, a refusal) is judged again, and a stale or
  # expired fact always is.
  @unbanded_reasons [:no_fact, :superseded]

  defp already_banded(name, reply, reason, opts) when reason in @unbanded_reasons do
    declared = Questions.declared(name)
    term = Quality.subject_term(reply)
    digest = Quality.digest(reply)
    mode = Keyword.get(opts, :mode, :live)

    Judgment
    |> Ash.Query.filter(
      subject_type == ^term["type"] and subject_id == ^term["id"] and
        question_hash == ^declared.question_hash and state_digest == ^digest and
        mode == ^mode and exists(Banding, parent(id) in observation_ids)
    )
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(
      actor: Keyword.get(opts, :actor, SystemActor.oban()),
      tenant: Keyword.fetch!(opts, :tenant)
    )
    |> case do
      nil -> nil
      observation -> observation.id
    end
  end

  defp already_banded(_name, _reply, _reason, _opts), do: nil

  defp status(reply, name, digests, opts) do
    Query.status(facts(opts), Quality.subject_term(reply), predicate(name),
      current_digests: digests
    )
  end

  defp names(opts), do: Keyword.get(opts, :questions) || Questions.names()

  defp facts(opts), do: Keyword.get(opts, :facts_resource, @facts)

  defp ensure_evaluation_replies!(replies) do
    case Enum.reject(replies, &evaluation_reply?/1) do
      [] ->
        :ok

      [reply | _] ->
        raise ArgumentError,
              "only evaluation replies (#{@evaluation_prefix}<run_id>/<case_id>/<epoch>) are " <>
                "graded; got #{inspect(reply.id)}"
    end
  end

  @instrument_keys [:model_version, :model_digest, :runtime_version]

  defp instrument!(opts) do
    instrument = Keyword.get(opts, :instrument)

    if is_map(instrument) and Enum.all?(@instrument_keys, &is_binary(Map.get(instrument, &1))) do
      Map.take(instrument, @instrument_keys)
    else
      raise ArgumentError,
            "grading needs :instrument with string #{inspect(@instrument_keys)}; " <>
              "a judgment without them can never become a calibration sample"
    end
  end

  defp evaluation_reply?(%{id: @evaluation_prefix <> _}), do: true
  defp evaluation_reply?(_reply), do: false

  # The error's class only: a message can carry the text it was about. The
  # judge is an Ash action, so its error is always an Ash error struct.
  defp reason_class(%module{}), do: inspect(module)
end
