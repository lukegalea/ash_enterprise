defmodule AshEnterprise.Process.DesignerCatalogue do
  @moduledoc """
  What the BPMN designer's properties panel offers, in this application's terms.

  `AshBpmn.Web.DesignerLive` takes three optional `{module, function, args}` tuples — called
  as `module.function(args ++ [socket])` on mount and every navigation, errors rescued to
  empty — and renders typed panels from what they return instead of free-text fields. The
  three functions below are those tuples.

  The important property is the second one: the action catalogue is **derived from
  `AshEnterprise.Process.ActionInvoker`'s registry**, not written alongside it. The registry
  is the reviewed allowlist; the panel is a rendering of it. A ref cannot be offered to a
  modeller without having been reviewed in code, because offering and permitting are the same
  list by construction.
  """

  use AshEnterpriseWeb, :verified_routes

  require Logger

  alias AshEnterprise.Process.ActionInvoker
  alias AshEnterpriseWeb.Bpmn.Helpers

  @doc """
  The decision keys this actor can see, as the business rule panel renders them.

  Read under the signed-in actor and their tenant — the same two facts the engine's other
  LiveViews act on (`Helpers.current_actor`, and `:current_tenant` from the router's
  `assign_tenant` on_mount) — so the panel offers what this actor could actually evaluate,
  policies included.
  """
  def decisions(socket) do
    AshDecisions.Catalogue.entries(AshEnterprise.Decisions,
      scope: [actor: Helpers.current_actor(socket), tenant: socket.assigns[:current_tenant]]
    )
  rescue
    e ->
      # The designer degrades to free text on an empty list, which is the right shape for a
      # catalogue that could not be read; keeping the log here means the outage is visible
      # rather than merely quiet.
      Logger.warning("designer decision catalogue failed: #{Exception.message(e)}")
      []
  end

  @doc "The actions a process may invoke — the invoker's registry, rendered."
  def actions(_socket), do: ActionInvoker.catalogue()

  @doc "Where the \"Edit decision ↗\" link on a business rule task points."
  def decision_editor_path(key, _socket), do: ~p"/app/decisions/#{key}/editor"
end
