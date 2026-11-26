defmodule AshEnterprise.Provenance.Why do
  @moduledoc """
  An `AshProvenance.Explanation` as rows a person reads, in one shape for every
  surface that shows it: the Why page (`AshEnterpriseWeb.A2ui.WhyUI`) and the
  assistant's `explain` tool (`AshEnterprise.Assistant.Lookups.Work`). One
  function means one answer, so the page and `/mcp` cannot drift apart.

  A row is a step or a gap, steps first in the order the walk found them. Its
  keys are `kind` (`:step`, `:gap`), `relation` (the PROV-DM relation or the gap's
  kind), `what` (the relation in words), `granularity`, and, when there is one,
  `value`, `masked?` (true when `value` is the masked text),
  `by`, `on_behalf_of`, `at`, `summary`, `plan`, `context`, `integrity`,
  `from`, `activity` and `correlation_id`.

  ## What a row never does

    * **Hide a hidden value as nothing.** A value the reader may not see is
      the masked text (`AshEnterpriseWeb.HiddenField.masked/0`), so it never
      reads as known and empty (ADR 0078, section 6). A step that shows no value
      has no `value` key at all.
    * **Pass a gap off as a step.** A gap says why the answer stops. An
      `:unreadable` gap carries its kind and nothing else, as the contract
      requires.
    * **Cut an answer silently.** An answer the walk cut short ends in a gap
      row that says at what depth and step count.
    * **Read as live what was not recorded.** A step with no execution context
      says `not recorded`.
  """

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Platform.LocalTime
  alias AshEnterpriseWeb.HiddenField
  alias AshProvenance.{Address, EntityRef, Gap, Integrity, Plan, Step}

  @doc """
  The rows of `explanation`. `correlation_ids` is the map beside it from each
  audit step's activity to the correlation id of the write it recorded.
  """
  @spec rows(AshProvenance.Explanation.t(), %{optional(String.t()) => String.t()}) :: [map()]
  def rows(explanation, correlation_ids) do
    Enum.map(explanation.steps, &step(&1, correlation_ids)) ++
      Enum.map(explanation.gaps, &gap/1) ++ cut(explanation.bounds)
  end

  defp step(%Step{} = step, correlation_ids) do
    compact(%{
      kind: :step,
      relation: step.relation,
      what: what(step.relation),
      granularity: step.granularity,
      value: value(step.value),
      masked?: step.value == :masked || nil,
      by: step.agent_label,
      on_behalf_of: step.on_behalf_of,
      at: stamp(step.at),
      summary: step.summary,
      plan: step.plan && Plan.format(step.plan),
      context: context(step.execution_context),
      integrity: integrity(step.integrity),
      from: step.antecedent && ref(step.antecedent),
      activity: step.activity,
      correlation_id: step.activity && Map.get(correlation_ids, step.activity)
    })
  end

  defp gap(%Gap{kind: :unreadable} = gap) do
    compact(%{kind: :gap, relation: :unreadable, what: what(:unreadable), from: of(gap)})
  end

  defp gap(%Gap{} = gap) do
    compact(%{
      kind: :gap,
      relation: gap.kind,
      what: what(gap.kind),
      at: stamp(gap.at),
      summary: gap.summary,
      from: of(gap),
      activity: gap.receipt
    })
  end

  defp cut(%{cut?: true} = bounds) do
    [
      %{
        kind: :gap,
        relation: :cut,
        what: what(:cut),
        summary:
          dgettext(
            "provenance",
            "Stopped at depth %{depth} of %{max_depth} and %{steps} of %{max_steps} steps.",
            depth: bounds.depth,
            max_depth: bounds.max_depth,
            steps: bounds.step_count,
            max_steps: bounds.max_steps
          )
      }
    ]
  end

  defp cut(_bounds), do: []

  defp value(nil), do: nil
  defp value(:masked), do: HiddenField.masked()
  defp value({:value, value}), do: to_string(value)

  defp of(%Gap{of: %Address{} = address}), do: Address.to_iri(address)
  defp of(%Gap{}), do: nil

  defp ref(%Address{} = address), do: Address.to_iri(address)
  defp ref(%EntityRef{resource: type, id: id}), do: type <> ":" <> Address.encode_id(id)

  defp stamp(nil), do: nil
  defp stamp(at), do: LocalTime.stamp(at)

  defp context(nil), do: dgettext("provenance", "not recorded")
  defp context(context), do: Atom.to_string(context)

  defp integrity(nil), do: nil

  defp integrity(%Integrity{anchor: anchor, status: status}),
    do: "#{anchor}: #{status}"

  defp what(:was_generated_by), do: dgettext("provenance", "set by")
  defp what(:was_derived_from), do: dgettext("provenance", "derived from")
  defp what(:used), do: dgettext("provenance", "used")
  defp what(:was_attributed_to), do: dgettext("provenance", "attributed to")
  defp what(:was_associated_with), do: dgettext("provenance", "done by")
  defp what(:acted_on_behalf_of), do: dgettext("provenance", "on behalf of")
  defp what(:was_invalidated_by), do: dgettext("provenance", "erased by")
  defp what(:was_revision_of), do: dgettext("provenance", "revision of")
  defp what(:had_primary_source), do: dgettext("provenance", "sourced from")
  defp what(:unreadable), do: dgettext("provenance", "not yours to read")
  defp what(:failed), do: dgettext("provenance", "could not be read")
  defp what(:erased), do: dgettext("provenance", "erased")
  defp what(:not_recorded), do: dgettext("provenance", "not recorded")
  defp what(:archived), do: dgettext("provenance", "past the archive")
  defp what(:cut), do: dgettext("provenance", "cut short")

  defp compact(row), do: Map.reject(row, fn {_key, value} -> is_nil(value) end)
end
