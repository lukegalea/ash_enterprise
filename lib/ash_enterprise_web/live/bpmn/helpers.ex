defmodule AshEnterpriseWeb.Bpmn.Helpers do
  @moduledoc """
  What the process engine's LiveViews need from this application's session.

  `ash_bpmn` reads `:current_user` and `:current_tenant` out of the socket's assigns
  (`AshBpmn.Scope.from_assigns/1`). This application assigns only `:current_user` — the
  authorization context is attached to it by `AshEnterpriseWeb.Plugs.LoadActorContext`, and the
  tenant is read back off that rather than assigned separately, because two sources for the
  same fact is how they come to disagree.

  So the tenant is derived here, through `ActorContext.tenant/1`, which is the accessor the
  rest of the application uses. **Never `actor.organization_id`**: `Accounts.User` is
  `tenant?: false` and has no such attribute, so that read raises rather than returning nil.
  """

  alias AshEnterprise.Security.ActorContext

  @doc "An `on_mount` hook that supplies `:current_tenant` for the engine's LiveViews."
  def on_mount(:assign_tenant, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_tenant, tenant(socket))}
  end

  @doc "The signed-in actor, with its authorization context already attached."
  def current_actor(socket), do: socket.assigns[:current_user]

  @doc "The principal ids a task list joins on: the user, plus their teams."
  def current_principal_ids(socket) do
    case socket.assigns[:current_user] do
      nil -> []
      user -> user |> ActorContext.for_actor() |> Map.get(:principal_ids, [])
    end
  end

  defp tenant(socket) do
    case socket.assigns[:current_user] do
      nil -> nil
      user -> ActorContext.tenant(user)
    end
  end
end
