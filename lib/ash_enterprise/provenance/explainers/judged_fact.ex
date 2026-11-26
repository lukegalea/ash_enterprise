defmodule AshEnterprise.Provenance.Explainers.JudgedFact do
  @moduledoc """
  Where a judged fact came from (ADR 0078, section 4): the package explainer
  for `SystemOne.Fact`'s `value`. The chain is the package's
  (`AshJudgments.Explain`): the banding that admitted the fact, the DMN
  evaluation and the rules it matched, the judgment observations the band table
  read, and the atoms those observations cited.

  The package reads nothing, so this module does the reading, and every read is
  the reader's own, through the resource's code interface with their actor and
  tenant: a banding, an evaluation or an observation the reader may not read is
  an `:unreadable` gap that carries no identifier, never a bypass. These rows are
  append-only and the fact names them, so a read that returns nothing is a row
  the reader's policy withholds (a filter, not an error): it is reported
  `:unreadable`, not `:not_recorded`. A fact with no admission at all is the
  `:not_recorded` one. The atom text
  is never read — a step shows an atom's address and when it was recorded. An
  atom that no longer resolves is an `:erased` gap; the atoms are the evidence
  package's, which has no read policy of its own, so nothing is `:unreadable`
  there.

  A fact whose value the reader may not see passes to the generic explainers,
  which mask it. The fact itself is not dispatched further: the answer's
  antecedents are addresses of the chain, not subjects of this walk.
  """

  @behaviour AshEnterprise.Provenance.Explainer

  alias AshEnterprise.Decisions
  alias AshEnterprise.SystemOne
  alias AshEnterprise.SystemOne.Fact
  alias AshProvenance.Gap

  @impl true
  def explain(%{value: %Ash.ForbiddenField{}}, _ctx), do: :pass

  def explain(%{resource: Fact, field: :value, record: fact} = subject, ctx) do
    case links(fact, ctx) do
      {:ok, links} ->
        {:ok, answer(fact, links, subject, ctx)}

      :failed ->
        {:ok,
         %{
           steps: [],
           gaps: [Gap.new!(kind: :failed, of: subject.address)],
           antecedents: [],
           correlation_ids: %{}
         }}
    end
  end

  def explain(_subject, _ctx), do: :pass

  defp answer(fact, links, subject, ctx) do
    {:ok, explanation} =
      AshJudgments.Explain.fact(fact, links,
        base: ctx.base,
        types: [fact: subject.address.type],
        atoms: &atoms(&1, &2, ctx)
      )

    %{steps: explanation.steps, gaps: explanation.gaps, antecedents: [], correlation_ids: %{}}
  end

  defp atoms(address, ids, ctx) do
    AshEvidence.Explanation.provenance(address, ids, actor: ctx.actor)
  end

  # -- The records the package walks, read as the reader ------------------

  # A fact with no admission, or entered by a person, has no banding to read.
  defp links(%{admission_id: nil}, _ctx), do: {:ok, %{}}
  defp links(%{admission_grade: :person}, _ctx), do: {:ok, %{}}

  defp links(%{admission_id: id}, ctx) do
    opts = [actor: ctx.actor, tenant: ctx.tenant]

    case read(SystemOne.get_banding(id, opts)) do
      {:ok, unread} when unread in [:unreadable, nil] -> {:ok, %{banding: :unreadable}}
      {:ok, banding} -> with_banding(banding, opts)
      :failed -> :failed
    end
  end

  defp with_banding(banding, opts) do
    with {:ok, evaluation} <- read(Decisions.get_evaluation(banding.decision_evaluation_id, opts)),
         {:ok, observations} <- observations(banding.observation_ids, opts) do
      {:ok,
       %{
         banding: banding,
         evaluation: evaluation || :unreadable,
         observations: observations
       }}
    end
  end

  defp observations(ids, _opts) when ids in [nil, []], do: {:ok, []}

  defp observations(ids, opts) do
    case read(SystemOne.list_judgments(opts ++ [query: [filter: [id: [in: ids]]]])) do
      {:ok, []} -> {:ok, :unreadable}
      other -> other
    end
  end

  # A record the reader may not read is a link the package turns into an
  # `:unreadable` gap; anything else that goes wrong is a failed read, which
  # the answer says.
  defp read({:ok, value}), do: {:ok, value}
  defp read({:error, %Ash.Error.Forbidden{}}), do: {:ok, :unreadable}
  defp read({:error, _other}), do: :failed
end
