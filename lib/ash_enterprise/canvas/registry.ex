defmodule AshEnterprise.Canvas.Registry do
  @moduledoc """
  The host's canvas registry: every Ash domain this application ships, in one
  list.

  This is the dev-only `/canvas` surface's discovery surface, with the same
  visibility posture as `/clarity`: everything the application defines is
  traversable, because the audience is a developer inspecting their own
  system. Audience gating (a tenant seeing only their slice) is a later
  phase — the registry is the single place that decision will land, and
  nothing else in the canvas stack needs to change when it does.

  Implementing `AshA2ui.Canvas.Registry` means this list is the *entire*
  discovery surface: the canvas resolver matches client refs against these
  domains as strings and never loads a module the registry does not name.
  """

  @behaviour AshA2ui.Canvas.Registry

  @domains [
    AshEnterprise.Accounts,
    AshEnterprise.AI,
    AshEnterprise.Audit,
    AshEnterprise.Bpmn,
    AshEnterprise.CanonicalAgent,
    AshEnterprise.Contracts,
    AshEnterprise.Decisions,
    AshEnterprise.Legacy,
    AshEnterprise.Legacy.Twins,
    AshEnterprise.LegacyAgent,
    AshEnterprise.Process,
    AshEnterprise.Reference,
    AshEnterprise.Security
  ]

  @impl true
  def domains, do: @domains

  @impl true
  def label(:application), do: "Ash Enterprise"

  def label(_other), do: nil
end
