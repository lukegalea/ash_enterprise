defmodule Battery.Bpmn.Token do
  @moduledoc """
  The battery's process tokens — routing, never business data.
  """

  use AshBpmn.Resources.Token,
    domain: Battery.Domain,
    repo: Battery.Repo,
    instance: Battery.Bpmn.Instance

  policies do
    bypass do
      authorize_if always()
    end
  end
end
