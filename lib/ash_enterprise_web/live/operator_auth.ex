defmodule AshEnterpriseWeb.OperatorAuth do
  @moduledoc """
  The door in front of operator-only surfaces (`/app/erasure`).

  The erasure scope privileges are reserved to the Platform Operator
  (`AshEnterprise.Security.Privilege.operator_only?/1`), so the policies
  already show anyone else an empty list. The door exists so they are told
  that, instead of looking at a blank page: an actor without a read grant on
  erasure scopes is sent to Today with a flash. Behind it the surface reads as
  the actor exactly as before — the door decides nothing the policies do not.
  """

  use AshEnterpriseWeb, :verified_routes

  alias AshEnterprise.Security.ActorContext

  def on_mount(:erasure_operator_required, _params, _session, socket) do
    if erasure_operator?(socket.assigns[:current_user]) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Erasure scopes are for the platform operator.")
       |> Phoenix.LiveView.redirect(to: ~p"/app/today")}
    end
  end

  @doc "Whether `actor` holds a read grant on erasure scopes (the operator's privilege)."
  def erasure_operator?(nil), do: false

  def erasure_operator?(actor) do
    context = ActorContext.for_actor(actor)
    grant = ActorContext.grant(context, AshEnterprise.Erasure.Scope, :read)

    context.system? or grant.global? or grant.basic? or MapSet.size(grant.business_unit_ids) > 0
  end
end
