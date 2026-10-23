# Compiled only when ash_agent_tools is loaded (dev and test); see
# AshEnterprise.Standards.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Standing) do
  defmodule AshEnterprise.Standards.Standing do
    @moduledoc """
    The standing job over a checkout of `main`, run after each merge:
    assess, judge, admit.

    1. **Assess.** `AshAgentTools.CodeSubjects.Standing.assess/4` scans the
       checkout under each question's projection and reads the facts table
       against the units' current digests. A unit edited since its fact was
       admitted reads `:stale`, a new unit `:no_fact`. Only the candidates
       `AshEnterprise.Standards.Candidates` selects are kept. Nothing here
       calls a model.
    2. **Judge.** Each pending unit goes to its question's generated judge
       action, through the host judge context
       (`AshEnterprise.SystemOne.judge_context/1`) and the in-zone transport
       (`AshEnterprise.SystemOne.DecisionWire`). The answer is recorded in
       the judgment ledger, under the code unit's subject term.
    3. **Admit.** The recorded answer goes through the host banding step
       (`AshEnterprise.SystemOne.Banding.Step.band/2`): the family's band
       table decides admit, review or omit, and the materialiser writes the
       fact, carrying the unit's digest. A family with no published band
       table admits nothing: the answer stays in the ledger, the step
       returns the resolver's error, and the unit reads `unknown`.

    ## Units too large to judge

    Units are chunked to fit the decision model's context: by default
    `winnow:e4b`'s 8,192 tokens, with 1,024 kept for the question and the
    answer. A unit whose declared context alone does not fit (a DSL entity
    in a module with a very long `policies` section, say) cannot be
    chunked. It does not stop the scan: `assess/2` returns it with the
    reason `:context_too_large`, and `run/2` reports it with the result
    `{:skipped, :context_too_large}` instead of sending it to the judge.

    `statuses/3` and `violations/2` are the filters: every candidate unit's
    current status, rolled up over its chunks
    (`AshAgentTools.CodeSubjects.Standing.statuses/4`), and the units whose
    status says they break their standard.

    Every fact is written and read under
    `AshEnterprise.Standards.subject_term/1`, so the subject type is
    `"AshEnterprise.Standards.CodeUnit"` throughout.

    ## Options

      * `:repository`: the repository name in each subject id (default
        `"ash_enterprise"`)
      * `:questions`: the question names to run (default: all twenty-three)
      * `:paths`: overrides each question's scan paths
      * `:limit`: at most this many pending units per question
      * `:max_tokens`, `:reserve_tokens`: the chunking budget (default
        8,192 and 1,024, `winnow:e4b`'s context)
      * `:facts_resource`: default `AshEnterprise.SystemOne.Fact`

    `run/2` also takes `:tenant` (required: the ledger and the bandings are
    held per tenant), `:actor` (default the `oban` system actor),
    `:judgments` (extra judge-context entries, such as a test transport),
    `:resolver` (the band-table resolver; the step's default otherwise),
    `:mode` (`:live` by default) and `:correlation_id`.
    """

    alias AshAgentTools.CodeSubjects
    alias AshAgentTools.CodeSubjects.Standing, as: CodeStanding
    alias AshEnterprise.Platform.Correlation
    alias AshEnterprise.Platform.SystemActor
    alias AshEnterprise.Standards
    alias AshEnterprise.Standards.{Candidates, CodeUnit, Questions}
    alias AshEnterprise.SystemOne
    alias AshEnterprise.SystemOne.Banding.Step

    @facts AshEnterprise.SystemOne.Fact
    @repository "ash_enterprise"

    # The :winnow_gpu profile's model, winnow:e4b, has an 8k context; the
    # reserve keeps room for the question's instructions, criteria and the
    # answer.
    @max_tokens 8192
    @reserve_tokens 1024

    @doc """
    The candidate units whose facts are missing, stale or expired, per
    question: `%{question => [{subject, reason}]}`. A unit too large for
    the decision model comes back as its chunks, and one whose declared
    context alone cannot fit comes back whole as `:context_too_large`.
    """
    @spec assess(Path.t(), keyword()) :: %{atom() => [{map(), atom()}]}
    def assess(root, opts \\ []) do
      Map.new(questions(opts), fn question ->
        ids = candidate_ids(root, question, opts)
        predicate = predicate(question)

        pending =
          root
          |> CodeStanding.assess(facts(opts), predicate, standing_opts(question, opts))
          |> Enum.filter(fn {subject, _reason} -> unit_id(subject) in ids end)
          |> maybe_take(opts[:limit])

        {question.name, pending}
      end)
    end

    @doc """
    Assesses, judges and admits (see the moduledoc). Returns one entry per
    assessed unit: `%{question, subject_id, location, reason,
    observation_id, result}`, where `result` is the banding step's
    (`{:ok, %{band: ...}}`, `{:refusal, ...}` or `{:error, ...}`),
    `{:error, ...}` from the judge, or `{:skipped, :context_too_large}` for
    a unit that was not judged because its context cannot fit.
    """
    @spec run(Path.t(), keyword()) :: [map()]
    def run(root, opts) do
      unless Keyword.has_key?(opts, :tenant), do: raise(ArgumentError, "run/2 needs :tenant")

      root
      |> assess(opts)
      |> Enum.sort_by(fn {name, _} -> Enum.find_index(Questions.names(), &(&1 == name)) end)
      |> Enum.flat_map(fn {name, pending} ->
        question = Questions.fetch!(name)

        Enum.map(pending, fn {subject, reason} ->
          {observation_id, result} =
            case reason do
              :context_too_large -> {nil, {:skipped, :context_too_large}}
              _reason -> judge_and_admit(question, subject, opts)
            end

          %{
            question: name,
            subject_id: subject.id,
            location: subject.location,
            reason: reason,
            observation_id: observation_id,
            result: result
          }
        end)
      end)
    end

    @doc """
    One unit through the judge and the banding step: the judged answer is
    recorded under a fresh observation id, then banded. Returns
    `{observation_id, result}`; the id is `nil` when the judge failed.
    """
    @spec judge_and_admit(map(), map(), keyword()) :: {Ash.UUID.t() | nil, term()}
    def judge_and_admit(question, subject, opts) do
      declared = Questions.declared(question.name)
      tenant = Keyword.fetch!(opts, :tenant)
      actor = Keyword.get(opts, :actor, SystemActor.oban())
      correlation_id = Keyword.get(opts, :correlation_id) || Correlation.id()
      observation_id = Ash.UUID.generate()
      term = Standards.subject_term(subject)

      context =
        SystemOne.judge_context(
          tenant: tenant,
          correlation_id: correlation_id,
          judgments:
            Map.merge(
              %{
                req_llm: SystemOne.DecisionWire,
                subject: %{type: term["type"], id: term["id"]},
                observation_id: observation_id,
                mode: Keyword.get(opts, :mode, :live)
              },
              Keyword.get(opts, :judgments, %{})
            )
        )

      judged =
        CodeUnit
        |> Ash.ActionInput.for_action(
          Questions.judge_action(question.name),
          %{"input" => subject},
          actor: actor
        )
        |> Ash.run_action(context: context)

      case judged do
        {:ok, answer} ->
          {observation_id,
           Step.band(
             [%{question: declared, answer: answer, observation_id: observation_id}],
             [
               family: to_string(declared.family),
               tenant: tenant,
               subject: term,
               predicate: declared.question_id,
               subject_state_digest: CodeSubjects.digest(subject, question.projection),
               holds_value: question.holds_value,
               correlation_id: correlation_id,
               mode: Keyword.get(opts, :mode, :live),
               facts_resource: facts(opts)
             ] ++ Keyword.take(opts, [:resolver])
           )}

        {:error, error} ->
          {nil, {:error, error}}
      end
    end

    @doc """
    Every candidate unit's current status for one question, rolled up over
    its chunks with the question's `roll_up` mode:
    `[{unit, :in | :out | {:unknown, reasons}}]`.
    """
    @spec statuses(Path.t(), atom(), keyword()) :: [{map(), term()}]
    def statuses(root, name, opts \\ []) do
      question = Questions.fetch!(name)
      ids = candidate_ids(root, question, opts)

      root
      |> CodeStanding.statuses(
        facts(opts),
        predicate(question),
        Keyword.put(standing_opts(question, opts), :mode, question.roll_up)
      )
      |> Enum.filter(fn {unit, _status} -> unit.id in ids end)
    end

    @doc """
    The candidate units whose admitted facts say they break their standard,
    over the selected questions: `[%{question, clause, subject, status}]`.
    """
    @spec violations(Path.t(), keyword()) :: [map()]
    def violations(root, opts \\ []) do
      Enum.flat_map(questions(opts), fn question ->
        violating = Questions.violating_status(question)

        for {unit, ^violating} <- statuses(root, question.name, opts) do
          %{question: question.name, clause: question.clause, subject: unit, status: violating}
        end
      end)
    end

    @doc "The facts-table predicate a question's facts are stored under."
    @spec predicate(map()) :: String.t()
    def predicate(question), do: Questions.declared(question.name).question_id

    defp questions(opts) do
      case Keyword.get(opts, :questions) do
        nil -> Questions.all()
        names -> Enum.map(names, &Questions.fetch!/1)
      end
    end

    defp candidate_ids(root, question, opts) do
      root
      |> CodeSubjects.scan(scan_opts(question, opts))
      |> Map.fetch!(:subjects)
      |> Enum.filter(&Candidates.candidate?(question.name, &1))
      |> MapSet.new(& &1.id)
    end

    defp scan_opts(question, opts) do
      [
        repository: Keyword.get(opts, :repository, @repository),
        paths: Keyword.get(opts, :paths, question.paths),
        kinds: question.kinds,
        context: question.projection
      ]
    end

    defp standing_opts(question, opts) do
      question
      |> scan_opts(opts)
      |> Keyword.delete(:context)
      |> Keyword.merge(
        projection: question.projection,
        type: Standards.subject_type()
      )
      |> Keyword.merge(max_tokens: @max_tokens, reserve_tokens: @reserve_tokens)
      |> Keyword.merge(Keyword.take(opts, [:max_tokens, :reserve_tokens]))
    end

    defp facts(opts), do: Keyword.get(opts, :facts_resource, @facts)

    defp unit_id(%{chunk: %{parent_id: parent}}), do: parent
    defp unit_id(subject), do: subject.id

    defp maybe_take(list, nil), do: list
    defp maybe_take(list, limit), do: Enum.take(list, limit)
  end
end
