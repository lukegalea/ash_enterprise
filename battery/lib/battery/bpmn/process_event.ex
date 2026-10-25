defmodule Battery.Bpmn.ProcessEvent do
  @moduledoc """
  The battery's process event stream — where the engine records what each
  node did (including what a business-rule task PROMOTED onto the token).
  """

  use AshBpmn.Resources.ProcessEvent,
    domain: Battery.Domain,
    repo: Battery.Repo,
    instance: Battery.Bpmn.Instance

  policies do
    bypass do
      authorize_if always()
    end
  end
end
