defmodule AshEnterprise.Platform.ActionStepsTest do
  @moduledoc """
  `AshEnterprise.Test.ActionSteps`, the helper behind the guards that say one action carries
  every step another does. A guard is only worth having if it reports a step that is gone, so
  these remove one and look at what the comparison says.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Bpmn.Subscription
  alias AshEnterprise.Test.ActionSteps

  defp publish, do: Ash.Resource.Info.action(Subscription, :publish)

  defp without(action, index), do: %{action | changes: List.delete_at(action.changes, index)}

  defp index_of(action, predicate), do: Enum.find_index(action.changes, predicate)

  test "a removed change is reported missing" do
    action = publish()
    index = index_of(action, &match?(%Ash.Resource.Change{}, &1))
    assert index, "publish has no change to remove"

    removed = action |> Map.fetch!(:changes) |> Enum.at(index) |> ActionSteps.step()

    missing =
      ActionSteps.missing(
        ActionSteps.action_steps(action),
        ActionSteps.action_steps(without(action, index))
      )

    assert removed in missing
  end

  test "a removed validation is reported missing, whatever else wraps the same way" do
    action = publish()

    validations =
      for {%Ash.Resource.Change{change: {AshEvents.Events.ReplayValidationWrapper, _}} = c, i} <-
            Enum.with_index(action.changes),
          do: {c, i}

    assert length(validations) >= 2, "publish needs two validations to prove the mask is gone"

    {wrapped, index} = hd(validations)
    removed = ActionSteps.step(wrapped)

    missing =
      ActionSteps.missing(
        ActionSteps.action_steps(action),
        ActionSteps.action_steps(without(action, index))
      )

    assert missing == [removed]
    refute elem(removed, 0) == AshEvents.Events.ReplayValidationWrapper
  end

  test "wrapped and unwrapped forms of the same step compare equal" do
    validation = %Ash.Resource.Validation{
      validation: {Ash.Resource.Validation.Present, [attribute: :key]},
      where: [],
      on: [:update]
    }

    wrapped = %Ash.Resource.Change{
      change: {AshEvents.Events.ReplayValidationWrapper, [validation: validation, message: nil]},
      where: [],
      on: [:update]
    }

    assert ActionSteps.step(wrapped) == ActionSteps.step(validation)

    change = %Ash.Resource.Change{
      change: {Ash.Resource.Change.SetAttribute, [attribute: :a]},
      where: [],
      on: [:update]
    }

    replay = %{change | change: {AshEvents.Events.ReplayChangeWrapper, [change: change]}}

    assert ActionSteps.step(replay) == ActionSteps.step(change)
  end
end
