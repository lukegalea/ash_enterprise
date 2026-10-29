defmodule Battery.Bpmn.Instance do
  @moduledoc """
  The battery's process instances.
  """

  use AshBpmn.Resources.Instance,
    domain: Battery.Domain,
    repo: Battery.Repo,
    definition: Battery.Bpmn.Definition

  policies do
    bypass do
      authorize_if always()
    end
  end
end
