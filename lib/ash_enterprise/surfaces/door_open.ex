defmodule AshEnterprise.Surfaces.DoorOpen do
  @moduledoc """
  True when a surface door (`AshEnterprise.Surfaces.Doors`) is open for the
  actor: `authorize_if {AshEnterprise.Surfaces.DoorOpen, door: :lineage}`.

  For a command that fronts a gated surface, so the command is offered only
  where the surface is. `AshAcp.AvailableActions` prunes the ACP palette with
  `Ash.can?/3`, and the web's palette (`AshEnterpriseWeb.Shell`) is the same
  list, so a policy here is what keeps both from offering it.

  A simple check: it reads the precomputed `ActorContext` and never queries.
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Surfaces.Doors

  @impl true
  def describe(opts), do: "the #{opts[:door]} door is open for the actor"

  @impl true
  def match?(actor, _authorizer, opts), do: Doors.open?(Keyword.fetch!(opts, :door), actor)
end
