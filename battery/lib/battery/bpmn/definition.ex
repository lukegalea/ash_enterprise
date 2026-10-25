defmodule Battery.Bpmn.Definition do
  @moduledoc """
  The battery's BPMN definitions: the `AshBpmn.Resources.Definition` macro
  on the battery's own repo. XML is the single artifact; publish is one-way.
  """

  use AshBpmn.Resources.Definition,
    domain: Battery.Domain,
    repo: Battery.Repo

  policies do
    bypass do
      authorize_if always()
    end
  end
end
