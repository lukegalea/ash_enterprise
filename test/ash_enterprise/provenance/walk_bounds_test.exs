defmodule AshEnterprise.Provenance.WalkBoundsTest do
  @moduledoc """
  The walk's bounds (ADR 0078, decision on bounds): a walk cut by the step
  bound says so. There is no silent cap.
  """

  use AshEnterprise.DataCase, async: true

  alias AshEnterprise.Provenance.Walk
  alias AshEnterprise.Test.Provenance.{Registry, Thing}

  setup do
    thing =
      Thing
      |> Ash.Changeset.for_create(:create, %{a: "start"}, authorize?: false)
      |> Ash.create!()

    %{thing: thing, base: AshEnterprise.Provenance.base()}
  end

  test "a walk cut by the step bound reports it", %{thing: thing, base: base} do
    # d3 derives from d2, from d1, from a: one more derivation step than the
    # bound holds, and the third cut says so.
    iri = "#{base}/test_thing/#{thing.id}#d3"

    {:ok, %{explanation: explanation}} =
      Walk.explain(iri, registry: Registry, max_steps: 2)

    assert explanation.bounds.cut?
    assert explanation.bounds.max_steps == 2
    assert explanation.bounds.step_count == length(explanation.steps)
    assert explanation.bounds.step_count == 2
  end

  test "an uncut walk says so", %{thing: thing, base: base} do
    iri = "#{base}/test_thing/#{thing.id}#d1"

    {:ok, %{explanation: explanation}} =
      Walk.explain(iri, registry: Registry)

    refute explanation.bounds.cut?
    assert explanation.bounds.step_count == length(explanation.steps)
  end
end
