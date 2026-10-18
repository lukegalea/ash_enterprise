defmodule AshEnterpriseWeb.LiveUserAuthTest do
  @moduledoc """
  The connected mount's user arrives from the session without the plug's
  `ActorContext`; the on_mount attaches one, so policy checks read it rather
  than rebuild it per check, and an event rebuilds it afresh.
  """

  use AshEnterprise.DataCase, async: true

  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.LiveUserAuth

  setup do
    n = System.unique_integer([:positive])
    %{user: user} = Seeder.seed_tenant(name: "Live auth #{n}", unique_name: "live-auth-#{n}")
    %{user: user}
  end

  defp socket(user),
    do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

  test "a bare user gets a context attached", %{user: user} do
    socket = LiveUserAuth.with_actor_context(socket(user))

    assert %ActorContext{user_id: id, system?: false} =
             socket.assigns.current_user.__ash_enterprise_context__

    assert id == user.id
  end

  test "a user already carrying the plug's context keeps it", %{user: user} do
    context = %ActorContext{user_id: user.id, organization_id: Ash.UUID.generate()}
    socket = LiveUserAuth.with_actor_context(socket(ActorContext.attach(user, context)))

    assert socket.assigns.current_user.__ash_enterprise_context__ == context

    # An event rebuilds it from the person's roles as they are now.
    refreshed = LiveUserAuth.refresh_actor_context(socket)
    refute refreshed.assigns.current_user.__ash_enterprise_context__ == context
  end

  test "no user, no context" do
    assert LiveUserAuth.with_actor_context(socket(nil)).assigns.current_user == nil
  end
end
