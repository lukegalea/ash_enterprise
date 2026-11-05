defmodule AshEnterprise.SystemOne.JudgedFields.Assessor do
  @moduledoc """
  The default assessor behind `:reassess_judgments`: one stale or expired
  judged fact in, one judged, recorded, banded answer out.

  It drives the same seams every other judged answer in this host takes:

  1. **Judge and record** through `AshJudgments.Registry.Judge.judge_and_record/5`
     on the question's generated judge action, with the record's state as
     the judge input — so the observation's `state_digest` is the digest
     the record's `judgment_digests` holds, and the fact it leads to is
     fresh.
  2. **Band and route** through `AshEnterprise.SystemOne.Banding.Step.band/2`:
     the band table for the question's family decides admit, review or
     omit, and the materialiser writes (or truncates) the fact.

  Host configuration, read at call time from
  `config :ash_enterprise, AshEnterprise.SystemOne.JudgedFields`:
  `:judgments` (extra judge-context entries, e.g. the transport in tests),
  `:resolver` (the band-table resolver; the step's default otherwise) and
  `:mode` (`:live` by default).

  Returns `{:ok, band_result}` or `{:refusal, ...}`/`{:error, ...}` as the
  step does; a judge failure is `{:error, error}`.
  """

  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.SystemOne
  alias AshEnterprise.SystemOne.Banding.Step
  alias AshEnterprise.SystemOne.JudgedFields
  alias AshEnterprise.SystemOne.JudgedState
  alias AshJudgments.Registry.Judge

  @doc "Assesses one selected question for one record (see the moduledoc)."
  def assess(
        %{field: field, state: state, digest: digest, subject: subject, tenant: tenant} = req
      ) do
    config = Application.get_env(:ash_enterprise, JudgedFields, [])
    question = field.question
    correlation_id = Correlation.id()

    input =
      Ash.ActionInput.for_action(req.resource, JudgedFields.judge_action(field), %{
        "input" => state
      })

    context =
      SystemOne.judge_context(
        tenant: tenant,
        correlation_id: correlation_id,
        lineage: Map.get(req, :lineage),
        judgments:
          Map.merge(
            %{subject: subject, mode: Keyword.get(config, :mode, :live)},
            Keyword.get(config, :judgments, %{})
          ),
        judged_state: JudgedState.project(question, input),
        judged_state_scope_id: scope_id(req)
      )

    input = Map.replace!(input, :context, context)

    case Judge.judge_and_record(question, input, context, context, question: field.name) do
      {:ok, answer, [observation_id]} ->
        Step.band(
          [%{question: question, answer: answer, observation_id: observation_id}],
          [
            family: to_string(question.family),
            tenant: tenant,
            subject: subject,
            predicate: field.question_id,
            subject_state_digest: digest,
            correlation_id: correlation_id
          ] ++ Keyword.take(config, [:resolver])
        )

      {:error, error, _partial} ->
        {:error, error}
    end
  end

  # The judged record's own erasure scope, when it is sealed under one: the
  # text it was judged on is shredded with it (ADR 0024).
  defp scope_id(%{record: %{erasure_scope_id: scope_id}}) when is_binary(scope_id), do: scope_id
  defp scope_id(_request), do: nil
end
