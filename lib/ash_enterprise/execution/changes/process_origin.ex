defmodule AshEnterprise.Execution.Changes.ProcessOrigin do
  @moduledoc """
  A run a process started names the instance that started it. The process engine's task
  (`AshEnterprise.Process.AgentRuns`) hands it over in the changeset context as
  `process_instance_id`; no caller can set it as an input.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Map.get(changeset.context, :process_instance_id) do
      nil -> changeset
      id -> Ash.Changeset.force_change_attribute(changeset, :process_instance_id, id)
    end
  end
end
