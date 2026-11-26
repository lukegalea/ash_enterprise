defmodule AshEnterprise.Provenance.Explainers.DerivedSecuredTest do
  @moduledoc """
  The derived explainer's secured-column rule (ADR 0078, section 6), as a unit:
  a calculation over a secured column names the column as its antecedent and
  dispatches nothing for it, whether or not the reader holds the grant.
  """

  use AshEnterprise.DataCase, async: true

  alias AshEnterprise.Provenance.Explainers.Derived
  alias AshEnterprise.Test.Provenance.Thing
  alias AshProvenance.Address

  @base "https://app.example.test/id"

  setup do
    thing =
      Thing
      |> Ash.Changeset.for_create(:create, %{a: "shown", sensitive: "secret"}, authorize?: false)
      |> Ash.create!()

    ctx = %{actor: nil, tenant: nil, base: @base, registry: nil, cache: %{}}
    %{thing: thing, ctx: ctx}
  end

  test "a calculation over a secured column names it and dispatches nothing", %{
    thing: thing,
    ctx: ctx
  } do
    {:ok, address} =
      Address.new(base: @base, type: "test_thing", id: thing.id, attribute: "over_sensitive")

    subject = %{
      address: address,
      resource: Thing,
      record: thing,
      field: :over_sensitive,
      value: Map.get(thing, :over_sensitive)
    }

    assert {:ok, answer} = Derived.explain(subject, ctx)

    assert [step] = answer.steps
    assert step.relation == :was_derived_from
    assert step.antecedent.attribute == "sensitive"
    # The secured column is never dispatch material.
    assert answer.antecedents == []
  end
end
