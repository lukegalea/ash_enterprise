defmodule AshEnterprise.SystemOne.JudgedFields.Calculation do
  @moduledoc """
  The derived judgment fields as one expression over the facts table
  (`AshEnterprise.SystemOne.JudgedFields`). Three modes share the same
  building blocks, with `AshJudgments.Query`'s semantics written as SQL:

  - a **candidate** fact is about this record (`subject_type`,
    `subject_id`), this question (`predicate`), in scope (the fact's scope
    contains every key of the asked scope; no asked scope reads only
    scope-less facts) and at or above the grade floor;
  - it is **stale** when it recorded a state digest and the record's
    current digest for the question differs (provable, never assumed);
  - it is **expired** when its domain validity (`valid_until`) has passed;
  - it is **live** when it is a candidate, neither stale nor expired.

  `:tri_state` is the `holds` of the live fact, a person-grade fact first,
  and `nil` when none is live. `:status` and `:reason` spell the same
  decision out. Facts are temporal: the subquery reads the version valid
  at the query's instant, like every other read of the facts table.

  The record's current digest is read from its `judgment_digests` map
  with Postgres's `->>`; this calculation is only meaningful in SQL, which
  is the point — no row is ever loaded into Elixir to decide membership.
  """

  use Ash.Resource.Calculation

  require Ash.Expr
  import Ash.Expr

  @impl true
  def init(opts) do
    if opts[:mode] in [:tri_state, :status, :reason] and is_binary(opts[:question_id]) and
         is_binary(opts[:subject_type]) do
      {:ok, opts}
    else
      {:error, "expected mode, question_id and subject_type"}
    end
  end

  @impl true
  def expression(opts, context) do
    args = context.arguments || %{}
    grades = grades_at_least(args[:min_grade] || :grant)
    about = about(opts[:subject_type], opts[:question_id], args[:scope])
    candidate = candidate(about, grades)
    stale = stale(opts[:question_id])
    expired = expired()
    live = live(candidate, stale, expired)

    parts = %{
      about: about,
      candidate: candidate,
      grades: grades,
      stale: stale,
      expired: expired,
      live: live,
      decided: decided(live)
    }

    mode(opts[:mode], parts)
  end

  # Each mode is one flat CASE: a CASE nested inside a CASE of another type
  # leaves Postgres to infer the inner literals' types from the outer one
  # (docs/BLEEDING-EDGE.md section 3), so the status and the reason spell
  # the tri-state's decision out again rather than reuse it.
  defp mode(:tri_state, %{decided: d}) do
    expr(
      cond do
        ^d.person_in -> true
        ^d.person_out -> false
        ^d.grant_in -> true
        ^d.grant_out -> false
        true -> nil
      end
    )
  end

  defp mode(:status, %{decided: d} = parts) do
    unusable = unusable(parts)

    expr(
      cond do
        ^d.person_in -> :admitted_true
        ^d.person_out -> :admitted_false
        ^d.grant_in -> :admitted_true
        ^d.grant_out -> :admitted_false
        ^unusable -> :stale
        true -> :not_assessed
      end
    )
  end

  defp mode(:reason, parts) do
    any_live = expr(exists(AshEnterprise.SystemOne.Fact, ^parts.live))
    stale = expr(exists(AshEnterprise.SystemOne.Fact, ^parts.candidate and ^parts.stale))
    expired = expr(exists(AshEnterprise.SystemOne.Fact, ^parts.candidate and ^parts.expired))
    below = below_grade(parts)

    expr(
      cond do
        ^any_live -> nil
        ^stale -> :stale
        ^expired -> :expired
        ^below -> :below_grade
        true -> :no_fact
      end
    )
  end

  # The live fact's verdict, a person-grade fact first (human-wins).
  defp decided(live) do
    %{
      person_in: live_with(live, :person, true),
      person_out: live_with(live, :person, false),
      grant_in: expr(exists(AshEnterprise.SystemOne.Fact, ^live and holds == true)),
      grant_out: expr(exists(AshEnterprise.SystemOne.Fact, ^live and holds == false))
    }
  end

  defp live_with(live, grade, holds) do
    expr(
      exists(
        AshEnterprise.SystemOne.Fact,
        ^live and admission_grade == ^grade and holds == ^holds
      )
    )
  end

  defp unusable(parts) do
    expr(
      exists(AshEnterprise.SystemOne.Fact, ^parts.candidate and (^parts.stale or ^parts.expired))
    )
  end

  defp below_grade(parts) do
    expr(
      exists(AshEnterprise.SystemOne.Fact, ^parts.about and admission_grade not in ^parts.grades)
    )
  end

  defp candidate(about, grades), do: expr(^about and admission_grade in ^grades)

  defp live(candidate, stale, expired), do: expr(^candidate and not (^stale) and not (^expired))

  defp expired, do: expr(not is_nil(valid_until) and valid_until <= now())

  # This record, this question, this scope. `subject_id` is text on the
  # facts table; the record's primary key is cast to match.
  defp about(subject_type, question_id, asked) do
    base =
      expr(
        subject_type == ^subject_type and predicate == ^question_id and
          subject_id == type(parent(id), :string)
      )

    case asked do
      nil ->
        expr(^base and is_nil(scope))

      asked when is_map(asked) ->
        expr(^base and fragment("(? @> ?::jsonb)", scope, ^asked))
    end
  end

  # Stale: the fact recorded a digest, the record has one for this question,
  # and they differ. Either side missing reads fresh (Query's stale?/2).
  defp stale(question_id) do
    current = expr(fragment("(? ->> ?)", parent(judgment_digests), ^question_id))

    expr(
      not is_nil(subject_state_digest) and not is_nil(^current) and
        subject_state_digest != ^current
    )
  end

  defp grades_at_least(min_grade),
    do:
      Enum.filter(AshJudgments.Facts.grades(), &AshJudgments.Facts.grade_at_least?(&1, min_grade))
end
