defmodule AshEnterprise.Provenance.Explainers.RecordColumns do
  @moduledoc """
  The ADR 0023 provenance columns, at record granularity (ADR 0078, section 4):
  who created the row and who last modified it, and on whose behalf — the part
  of the answer that survives any audit-retention window.

  The ids are named by label only, as far as the reader may read
  (`AshEnterprise.Provenance.Labels`); a creator or modifier never recorded is
  a `:not_recorded` gap, not a step. A resource without the columns (the log
  itself, a facade, a computed resource) passes.
  """

  @behaviour AshEnterprise.Provenance.Explainer

  alias AshEnterprise.Provenance.Labels
  alias AshProvenance.{EntityRef, Gap, Step}

  @impl true
  def explain(%{resource: resource} = subject, ctx) do
    if has_columns?(resource) do
      {:ok, answer(subject, ctx)}
    else
      :pass
    end
  end

  defp has_columns?(resource) do
    Enum.all?(
      [:created_by_id, :created_on, :modified_by_id, :modified_on],
      &Ash.Resource.Info.attribute(resource, &1)
    )
  end

  defp answer(subject, ctx) do
    record = subject.record

    {cache, creator} = label(ctx.cache, record.created_by_id, ctx)
    {cache, modifier} = label(cache, record.modified_by_id, ctx)
    {cache, on_behalf_creator} = label(cache, record.created_on_behalf_by_id, ctx)
    {cache, on_behalf_modifier} = label(cache, record.modified_on_behalf_by_id, ctx)

    {creator_steps, creator_gaps} = attribution(subject, creator, record.created_on, "created")

    {modifier_steps, modifier_gaps} =
      attribution(subject, modifier, record.modified_on, "last modified")

    steps =
      creator_steps ++
        behalf(subject, on_behalf_creator, creator, record.created_on) ++
        behalf(subject, on_behalf_modifier, modifier, record.modified_on) ++
        modifier_steps

    %{
      steps: steps,
      gaps: creator_gaps ++ modifier_gaps,
      antecedents: [],
      correlation_ids: %{},
      cache: cache
    }
  end

  # One person's label, read as the reader, once per call. Labels memoizes in
  # the walk's cache, keyed by user id.
  defp label(cache, id, ctx) do
    case Map.fetch(cache, {:user, id}) do
      {:ok, remembered} ->
        {cache, remembered}

      :error ->
        remembered = Labels.user_label(id, ctx)
        {Map.put(cache, {:user, id}, remembered), remembered}
    end
  end

  # One `was_attributed_to` step, or a `:not_recorded` gap when no id was
  # recorded. The label is the reader's: a person they may not read is "a
  # person", never an id (ADR 0078, section 6).
  defp attribution(subject, {:ok, agent_label}, at, summary) do
    {[
       Step.new!(
         relation: :was_attributed_to,
         entity: record_ref(subject),
         agent_label: agent_label,
         at: at,
         granularity: :record,
         summary: summary
       )
     ], []}
  end

  defp attribution(subject, :not_recorded, _at, _summary),
    do: {[], [Gap.new!(kind: :not_recorded, of: subject.address)]}

  # Impersonation (ADR 0023): when a write ran on a person's behalf, the person
  # whose authority it ran on was the creator or modifier, and whoever operated
  # acted for them. No attribution on either side, no step.
  defp behalf(_subject, on_behalf, {:ok, authority_label}, at) do
    case on_behalf do
      {:ok, operator_label} ->
        [
          Step.new!(
            relation: :acted_on_behalf_of,
            agent_label: operator_label,
            on_behalf_of: authority_label,
            at: at,
            granularity: :record
          )
        ]

      :not_recorded ->
        []
    end
  end

  defp behalf(_subject, _on_behalf, :not_recorded, _at), do: []

  defp record_ref(subject) do
    # The address already carries the type token, and carries it from the
    # registry the walk was built with: never re-read the module-level one,
    # which a swapped registry would not reach.
    EntityRef.new!(
      resource: subject.address.type,
      id: subject.address.id,
      version_number: version_number(subject.resource, subject.record),
      as_of: subject.address.as_of
    )
  end

  defp version_number(resource, record) do
    case Ash.Resource.Info.attribute(resource, :version_number) do
      nil -> nil
      _attribute -> Map.get(record, :version_number)
    end
  end
end
