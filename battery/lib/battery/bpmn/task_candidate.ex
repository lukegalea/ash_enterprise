defmodule Battery.Bpmn.TaskCandidate do
  @moduledoc """
  The battery's task candidates — candidate lists are rows, not queries.
  """

  use AshBpmn.Resources.TaskCandidate,
    domain: Battery.Domain,
    repo: Battery.Repo,
    task: Battery.Bpmn.HumanTask

  policies do
    bypass do
      authorize_if always()
    end
  end
end
