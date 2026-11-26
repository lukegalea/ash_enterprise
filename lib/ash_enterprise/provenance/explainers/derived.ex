defmodule AshEnterprise.Provenance.Explainers.Derived do
  @moduledoc """
  The derived-value explainer (ADR 0078, section 4): a calculation or an
  aggregate `was_derived_from` what it reads.

  It reads only resource metadata (`Ash.Resource.Info`) and the record already
  read as the reader — it makes no reads of its own. A module calculation names
  the fields its `load/3` returns; an expression calculation names the refs in
  its expression. Same-record fields are steps at value granularity and are
  dispatched again — except a secured column (ADR 0073), which is named as the
  antecedent and never dispatched, whether or not the reader holds its grant
  (ADR 0078, section 6: what a derivation reads of a secured column is exactly
  what the column's grant withholds). An aggregate, or a ref through a
  relationship, is one record-granularity step and is not recursed into: no
  per-row reads.

  A decrypting calculation over sealed content
  (`AshEnterprise.Erasure.Calculations.Unseal`) is not a derivation and passes.
  """

  @behaviour AshEnterprise.Provenance.Explainer

  alias AshEnterprise.Erasure.Calculations.Unseal
  alias AshEnterprise.Provenance.Explainer
  alias AshProvenance.{Address, Gap, Step}

  @impl true
  def explain(%{field: nil}, _ctx), do: :pass

  def explain(%{resource: resource, field: field} = subject, _ctx) do
    cond do
      aggregate = Ash.Resource.Info.aggregate(resource, field) ->
        {:ok, over_relationship(subject, "aggregate", path(aggregate))}

      calculation = Ash.Resource.Info.calculation(resource, field) ->
        calculation_answer(calculation, subject)

      true ->
        :pass
    end
  end

  # -- Calculations -------------------------------------------------------

  defp calculation_answer(calculation, subject) do
    case calculation.calculation do
      {Unseal, _opts} ->
        # It decrypts a sealed attribute; the audit explainer answers for it.
        :pass

      {AshCloak.Calculations.Decrypt, _opts} ->
        # The cloak's decrypting calculation over sealed content: the same
        # rule as Unseal — not a derivation, the audit explainer answers.
        :pass

      {Ash.Resource.Calculation.Expression, opts} ->
        refs_answer(Ash.Filter.list_refs(opts[:expr]), subject)

      module when is_atom(module) ->
        load_answer(module, [], subject)

      {module, opts} when is_atom(module) ->
        load_answer(module, opts, subject)

      _function ->
        # A function-based calculation has no metadata to read.
        :pass
    end
  end

  defp load_answer(module, opts, subject) do
    names =
      try do
        module.load(Ash.Query.new(subject.resource), opts, %{})
      rescue
        # A calculation that cannot say what it reads cannot be explained:
        # a failed gap, never an empty answer (which would read as "nothing
        # was derived").
        _uncallable ->
          {:error, :load}
      end

    case names do
      {:error, :load} ->
        {:ok,
         %{
           steps: [],
           gaps: [Gap.new!(kind: :failed, of: subject.address)],
           antecedents: [],
           correlation_ids: %{}
         }}

      names ->
        {steps, antecedents} = derived_from_fields(names |> load_names() |> Enum.uniq(), subject)

        {:ok, %{steps: steps, gaps: [], antecedents: antecedents, correlation_ids: %{}}}
    end
  end

  defp load_names(names) when is_list(names) do
    Enum.flat_map(names, fn
      name when is_atom(name) -> [name]
      {name, _opts} when is_atom(name) -> [name]
      _other -> []
    end)
  end

  defp load_names(_other), do: []

  # -- Expression refs ----------------------------------------------------

  defp refs_answer(refs, subject) do
    {same_record, through_relationship} =
      Enum.split_with(refs, &(&1.relationship_path == []))

    relationship_steps =
      through_relationship
      |> Enum.uniq_by(& &1.relationship_path)
      |> Enum.map(
        &over_relationship(subject, "calculation", Enum.join(&1.relationship_path, "."))
      )

    # A ref may name an aggregate of this record: its relationship is the
    # antecedent, not the aggregate field itself.
    {aggregate_refs, field_refs} =
      same_record
      |> Enum.uniq_by(& &1.attribute)
      |> Enum.split_with(&Ash.Resource.Info.aggregate(subject.resource, &1.attribute))

    aggregate_steps =
      Enum.map(aggregate_refs, &over_relationship(subject, "aggregate", path_of_ref(&1, subject)))

    {field_steps, antecedents} =
      derived_from_fields(Enum.map(field_refs, & &1.attribute) |> Enum.uniq(), subject)

    {:ok,
     %{
       steps: field_steps ++ relationship_steps ++ aggregate_steps,
       gaps: [],
       antecedents: antecedents,
       correlation_ids: %{}
     }}
  end

  defp path_of_ref(ref, subject) do
    case Ash.Resource.Info.aggregate(subject.resource, ref.attribute) do
      nil -> Atom.to_string(ref.attribute)
      aggregate -> path(aggregate)
    end
  end

  # -- Shared -------------------------------------------------------------

  # A same-record field is a value-granularity step and dispatch material,
  # unless it is a secured column: named, but never dispatched and never
  # recursed into (ADR 0078, section 6).
  @spec derived_from_fields([atom()], AshEnterprise.Provenance.Explainer.subject()) ::
          {[AshProvenance.Step.t()], [AshEnterprise.Provenance.Explainer.subject()]}
  defp derived_from_fields(fields, subject) do
    fields =
      Enum.filter(fields, fn field ->
        Enum.any?(
          [
            Ash.Resource.Info.attribute(subject.resource, field),
            Ash.Resource.Info.calculation(subject.resource, field)
          ],
          &(&1 && &1.public?)
        )
      end)

    steps =
      Enum.map(fields, fn field ->
        {:ok, antecedent_address} = Explainer.field_address(subject, field)

        # The step's value is the entity's (the subject's): the PROV-O export
        # puts a step's value on its entity node, so the antecedent's raw value
        # must never ride on it — least of all a sealed or shredded one.
        Step.new!(
          relation: :was_derived_from,
          entity: subject.address,
          antecedent: antecedent_address,
          granularity: :value,
          value: Explainer.render_value(subject.resource, subject.field, subject.value)
        )
      end)

    antecedents =
      fields
      |> Enum.reject(&Explainer.secured?(subject.resource, &1))
      |> Enum.map(&Explainer.field_subject(subject, &1))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, antecedent} -> antecedent end)

    {steps, antecedents}
  end

  # An aggregate, or a ref through a relationship: one record-granularity step
  # whose antecedent is the record itself through the relationship. Not
  # recursed into: no per-row reads.
  defp over_relationship(subject, kind, relationship) do
    {:ok, record_address} =
      Address.new(
        base: subject.address.base,
        type: subject.address.type,
        id: subject.address.id,
        as_of: subject.address.as_of,
        attribute: relationship
      )

    Step.new!(
      relation: :was_derived_from,
      entity: subject.address,
      antecedent: record_address,
      granularity: :record,
      summary: "#{kind} over #{relationship}",
      value: Explainer.render_value(subject.resource, subject.field, subject.value)
    )
  end

  defp path(aggregate) do
    aggregate.relationship_path
    |> List.wrap()
    |> Enum.join(".")
  end
end
