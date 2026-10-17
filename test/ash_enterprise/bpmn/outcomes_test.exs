defmodule AshEnterprise.Bpmn.OutcomesTest do
  @moduledoc """
  The declared-outcome check fails closed: a task whose step's outcomes cannot
  be read is refused, never treated as a step that declares none. A
  standalone approval (no instance) still accepts any outcome.
  """

  use AshEnterprise.DataCase, async: true

  alias AshEnterprise.Bpmn.Calculations.DeclaredOutcomes
  alias AshEnterprise.Bpmn.Outcomes

  test "a standalone approval declares none and accepts any outcome" do
    task = %{instance_id: nil, node_id: nil, organization_id: Ash.UUID.generate()}

    assert [{:ok, nil}] = DeclaredOutcomes.resolve([task])
    assert :ok = Outcomes.check(task, "approved", [])
  end

  test "a task whose instance cannot be read is refused, whatever the outcome" do
    task = %{
      instance_id: Ash.UUID.generate(),
      node_id: "Review",
      organization_id: Ash.UUID.generate()
    }

    assert [{:error, :unresolved}] = DeclaredOutcomes.resolve([task])
    assert {:error, message} = Outcomes.check(task, "approve", [])
    assert message =~ "could not be read"
  end
end
