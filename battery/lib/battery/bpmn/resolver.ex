defmodule Battery.Bpmn.Resolver do
  @moduledoc """
  The battery's `AshBpmn.AssignmentResolver`. The battery's processes have
  no human tasks, so candidate resolution declines honestly: no candidates,
  no exclusions.
  """

  def candidates(_specs, _ctx), do: {:ok, []}

  def exclusions(_specs, _ctx), do: {:ok, []}
end
