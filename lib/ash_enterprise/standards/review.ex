# Compiled only when ash_agent_tools is loaded (dev and test); see
# AshEnterprise.Standards.
if Code.ensure_loaded?(AshJudgments.Query) and
     Code.ensure_loaded?(AshAgentTools.CodeSubjects.Advisory) do
  defmodule AshEnterprise.Standards.Review do
    @moduledoc """
    The advisory review comment for a change: the iron-laws judge's report,
    and what the facts table says about each standards question over the
    units the change touches.

    The comment is `AshAgentTools.CodeSubjects.Advisory.review/3`'s, so its
    `laws` section is `AshAgentTools.Laws.judge/2`'s output, unchanged. The
    standards section is built only from facts and never alters the laws
    report or any exit status: System One is advisory here.

    A unit is touched when its lines overlap a hunk of the diff in the
    post-image. Each touched unit, of the kinds a question is asked over,
    that is a
    candidate for a question (`AshEnterprise.Standards.Candidates`) gives one
    finding, with the status `AshJudgments.Query.status/4` reads against the
    unit's current digest, rolled up over its chunks. A unit edited by the
    change reads `unknown (:stale)` until the standing job has judged it on
    `main`. A unit whose declared context alone exceeds the token budget
    reads `unknown (:context_too_large)`, as the standing job never judges
    it.
    """

    alias AshAgentTools.CodeSubjects
    alias AshAgentTools.CodeSubjects.Advisory
    alias AshEnterprise.Standards
    alias AshEnterprise.Standards.{Candidates, Questions, Standing}

    @facts AshEnterprise.SystemOne.Fact

    @doc """
    The review of `diff` (a unified diff) over the post-image checkout at
    `root`. Returns `AshAgentTools.CodeSubjects.Advisory.review/3`'s map:
    `%{laws:, advisory:, markdown:}`.

    Options: `:repository` (default `"ash_enterprise"`), `:questions`,
    `:facts_resource`, `:max_tokens`, `:reserve_tokens`, `:token_count` and
    `:laws_opts`
    (passed to the judge).
    """
    @spec review(Path.t(), String.t(), keyword()) :: map()
    def review(root, diff, opts \\ []) do
      Advisory.review(diff, findings(root, diff, opts), Keyword.take(opts, [:laws_opts]))
    end

    @doc "The standards findings for the units `diff` touches (see the moduledoc)."
    @spec findings(Path.t(), String.t(), keyword()) :: [map()]
    def findings(root, diff, opts \\ []) do
      repository = Keyword.get(opts, :repository, "ash_enterprise")
      hunks = CodeSubjects.from_diff(diff, repository: repository)
      paths = hunks |> Enum.map(& &1.path) |> Enum.uniq()

      for question <- questions(opts),
          unit <- touched(root, hunks, paths, question, repository),
          Candidates.candidate?(question.name, unit) do
        %{
          subject: unit,
          standard: question.clause,
          question_id: Standing.predicate(question),
          status: status(unit, question, opts),
          admitted?: true
        }
      end
      |> Enum.map(fn finding -> %{finding | admitted?: admitted?(finding.status)} end)
    end

    defp touched(_root, _hunks, [], _question, _repository), do: []

    defp touched(root, hunks, paths, question, repository) do
      units =
        root
        |> CodeSubjects.scan(
          repository: repository,
          paths: paths,
          kinds: question.kinds,
          context: question.projection
        )
        |> Map.fetch!(:subjects)

      hunks
      |> Enum.flat_map(&units_for(&1, units))
      |> Enum.uniq_by(& &1.id)
    end

    defp units_for(hunk, units) do
      lines = hunk_lines(hunk)
      Enum.filter(units, &(&1.path == hunk.path and overlaps?(&1.span, lines)))
    end

    defp hunk_lines(hunk), do: {hunk.span.start_line, hunk.span.end_line}

    defp overlaps?(%{start_line: a, end_line: b}, {c, d}), do: a <= d and c <= b

    defp status(unit, question, opts) do
      chunk_opts = Keyword.take(opts, [:max_tokens, :reserve_tokens, :token_count])

      case CodeSubjects.fit(unit, question.projection, chunk_opts) do
        {:ok, pieces} -> pieces_status(pieces, question, opts)
        {:error, {:context_too_large, _budget}} -> {:unknown, :context_too_large}
      end
    end

    defp pieces_status(pieces, question, opts) do
      predicate = Standing.predicate(question)
      facts = Keyword.get(opts, :facts_resource, @facts)

      statuses =
        Enum.map(pieces, fn piece ->
          term = Standards.subject_term(piece)

          AshJudgments.Query.status(facts, term, predicate,
            current_digests: %{term => CodeSubjects.digest(piece, question.projection)}
          )
        end)

      case statuses do
        [single] -> single
        many -> CodeSubjects.roll_up(many, question.roll_up)
      end
    end

    defp admitted?({decided, _fact}) when decided in [:in, :out], do: true
    defp admitted?(decided) when decided in [:in, :out], do: true
    defp admitted?(_status), do: false

    defp questions(opts) do
      case Keyword.get(opts, :questions) do
        nil -> Questions.all()
        names -> Enum.map(names, &Questions.fetch!/1)
      end
    end
  end
end
