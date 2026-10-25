defmodule Battery.Bpmn.HumanTask do
  @moduledoc """
  The battery's human tasks. The engine's domain resolution wants the full
  six-kind set; the battery's own processes have no human tasks, but the
  resource is instantiated the way a host does so the engine is whole.
  """

  use AshBpmn.Resources.HumanTask,
    domain: Battery.Domain,
    repo: Battery.Repo,
    instance: Battery.Bpmn.Instance,
    token: Battery.Bpmn.Token,
    task_candidate: Battery.Bpmn.TaskCandidate

  policies do
    bypass do
      authorize_if always()
    end
  end
end
