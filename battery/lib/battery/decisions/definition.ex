defmodule Battery.Decisions.Definition do
  @moduledoc """
  The battery's DMN definitions: the `AshDecisions.Resources.Definition`
  macro on the battery's own repo. The XML is the single artifact; publish
  is one-way.
  """

  use AshDecisions.Resources.Definition,
    domain: Battery.Domain,
    repo: Battery.Repo

  policies do
    bypass do
      authorize_if always()
    end
  end
end
