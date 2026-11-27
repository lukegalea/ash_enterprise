defmodule AshEnterprise.Provenance.WhyTest do
  @moduledoc """
  `AshEnterprise.Provenance.Why`: an explanation as rows, in the shape the Why page
  and the assistant's tool share. Pure: the explanation is built here.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Provenance.Why
  alias AshProvenance.{Address, EntityRef, Explanation, Gap, Step}

  @base "https://example.test/id"

  defp address(type \\ "task"),
    do: Address.new!(base: @base, type: type, id: "t1", attribute: "title")

  defp explanation(steps, gaps, bounds \\ %{}) do
    Explanation.new!(
      subject: address(),
      steps: steps,
      gaps: gaps,
      bounds:
        Map.merge(
          %{max_depth: 4, max_steps: 40, depth: 1, step_count: length(steps), cut?: false},
          bounds
        )
    )
  end

  defp step(fields) do
    Step.new!(
      Map.merge(
        %{
          relation: :was_attributed_to,
          entity: address(),
          agent_label: "Dana",
          granularity: :record
        },
        fields
      )
    )
  end

  test "a hidden value is the masked text, never empty" do
    [row] = Why.rows(explanation([step(%{value: :masked})], []), %{})

    assert row.masked?
    assert row.value == AshEnterpriseWeb.HiddenField.masked()
    assert row.value != ""
  end

  test "a step that shows no value has no value key, and a shown one is its text" do
    [none, shown] =
      Why.rows(explanation([step(%{}), step(%{value: {:value, 12}})], []), %{})

    refute Map.has_key?(none, :value)
    assert shown.value == "12"
    refute Map.has_key?(shown, :masked?)
  end

  test "a step with no execution context says so, never live" do
    [row] = Why.rows(explanation([step(%{})], []), %{})
    assert row.context == "not recorded"

    [row] = Why.rows(explanation([step(%{execution_context: :live})], []), %{})
    assert row.context == "live"
  end

  test "a used step names the record it used, and a delegated step names whom it was for" do
    grant =
      EntityRef.new!(resource: "agent_start_grant", id: "00000000-0000-0000-0000-000000000001")

    [used, behalf] =
      Why.rows(
        explanation(
          [
            step(%{
              relation: :used,
              entity: grant,
              activity: "dispatch:00000000-0000-0000-0000-000000000002"
            }),
            step(%{relation: :acted_on_behalf_of, on_behalf_of: "publisher@example.test"})
          ],
          []
        ),
        %{}
      )

    # A `:used` step has no antecedent: what it names is the record it used.
    assert used.from == "agent_start_grant:00000000-0000-0000-0000-000000000001"
    assert behalf.by == "Dana"
    assert behalf.on_behalf_of == "publisher@example.test"
  end

  test "an unreadable gap carries its kind and what it was of, and nothing else" do
    gap = Gap.new!(kind: :unreadable, of: address("task"))
    [row] = Why.rows(explanation([], [gap]), %{})

    assert Map.keys(row) |> Enum.sort() == [:from, :kind, :relation, :what]
    assert row.relation == :unreadable
  end

  test "an answer the walk cut short ends in a row that says so" do
    rows = Why.rows(explanation([step(%{})], [], %{cut?: true, depth: 4}), %{})

    assert %{kind: :gap, relation: :cut, summary: summary} = List.last(rows)
    assert summary =~ "depth 4 of 4"
  end
end
