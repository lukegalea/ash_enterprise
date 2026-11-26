defmodule AshEnterprise.Provenance.Explainers.Facade do
  @moduledoc """
  The ontology-facade explainer (ADR 0083, decision 8; ADR 0078, section 4): a
  facade value `was_derived_from` the source value its lens reads, and the walk
  then asks the source's own explainers about that value, with the same reader.
  A facade over a facade is two such hops.

  The lens step is the package's (`AshStrangler.Facade.Explain`): it reads
  nothing and answers from the facade record the walk already read as the
  reader. This module reads the source value the step names, once, as the
  reader and through the source's own read, and hands it back to the walk as
  the antecedent. A source row the reader cannot read now is an `:unreadable`
  gap with no identifier, never the source's own Forbidden or NotFound.

  A secured column (ADR 0073) of the source is named by the step and never
  dispatched, whether or not the reader holds its grant: what a derivation
  reads of it is what its grant withholds (ADR 0078, section 6), the same rule
  the derived-value explainer keeps.

  Only a resource that carries `AshStrangler.Facade` is answered for; any other
  passes.
  """

  @behaviour AshEnterprise.Provenance.Explainer

  alias AshEnterprise.Provenance.{Explainer, Walk}
  alias AshProvenance.Gap
  alias AshStrangler.Facade.{Explain, Info}

  @impl true
  def explain(%{field: nil}, _ctx), do: :pass

  def explain(%{resource: resource, field: field} = subject, ctx) do
    case Info.source(resource) do
      nil -> :pass
      source -> {:ok, answer(subject, field, source, ctx)}
    end
  end

  defp answer(subject, field, source, ctx) do
    case ctx.registry.token(source) do
      {:ok, source_type} ->
        lens =
          Explain.value(subject.record, field,
            address: subject.address,
            source_type: source_type,
            value: Explainer.render_value(subject.resource, field, subject.value)
          )

        antecedents(lens, subject, source, ctx)

      # A source with no type token has no address to name: the step cannot be
      # written, so the answer is that explaining failed, not that nothing
      # happened.
      :error ->
        gaps_only(Gap.new!(kind: :failed, of: subject.address))
    end
  end

  defp antecedents(lens, subject, source, ctx) do
    {subjects, gaps} =
      Enum.reduce(lens.antecedents, {[], []}, fn address, {subjects, gaps} ->
        case Walk.read_subject(address, source, ctx) do
          {:ok, source_subject} ->
            {subjects ++ dispatchable(source_subject), gaps}

          # The source row is not one this reader may read now. The step that
          # named it is dropped with the rest of its answer: it would be the
          # only place its identifier appeared.
          {:error, _not_found} ->
            {subjects, gaps ++ [Gap.new!(kind: :unreadable, of: subject.address)]}
        end
      end)

    if gaps == [] do
      %{steps: lens.steps, gaps: lens.gaps, antecedents: subjects, correlation_ids: %{}}
    else
      %{steps: [], gaps: lens.gaps ++ Enum.uniq(gaps), antecedents: [], correlation_ids: %{}}
    end
  end

  defp dispatchable(%{field: field, resource: resource} = source_subject) do
    if field && Explainer.secured?(resource, field), do: [], else: [source_subject]
  end

  defp gaps_only(gap), do: %{steps: [], gaps: [gap], antecedents: [], correlation_ids: %{}}
end
