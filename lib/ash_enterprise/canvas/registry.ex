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

  @doc """
  Which projections an object carries, where action shape cannot say.

  The library derives projections from a resource's actions — a read makes it
  browsable, a create makes it creatable — which is everything CRUD can
  describe and none of what makes a process definition different from a
  business unit. Their actions are identical. What differs is that this
  application ships a renderer for one of them, and that is a fact about the
  host, not about the resource.

  `:diagram` is declared only where a diagram genuinely exists: a BPMN process
  definition, drawn by bpmn-js, and a DMN decision, drawn by dmn-js. It is
  deliberately *not* declared on `Bpmn.Instance`, even though a running
  instance is the most diagram-like thing here — a single instance is drawn on
  the definition it pinned, at `/app/instances/:id`, and there is no route that
  draws instances in general. A projection is a claim that something can be
  rendered, so claiming it at resource level where only records can be rendered
  would make the object model say something untrue.

  `:history` stays unemitted for the same reason. `Bpmn.ProcessEvent` is
  literally a process's history, but nothing in this application renders it as
  one yet, and a projection nothing can open is the defect this callback exists
  to fix rather than to relocate.
  """
  @impl true
  def projections(AshEnterprise.Bpmn.Definition, derived), do: derived ++ [:diagram]
  def projections(AshEnterprise.Decisions.Definition, derived), do: derived ++ [:diagram]
  def projections(_other, _derived), do: nil
end
