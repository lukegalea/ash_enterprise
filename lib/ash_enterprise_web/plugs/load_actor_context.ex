defmodule AshEnterpriseWeb.Plugs.LoadActorContext do
  @moduledoc """
  Resolves the signed-in user's full authorization context once per request and
  attaches it to the actor.

  This plug is what makes the rule in `docs/manifesto/03-authorization-is-data.md`
  enforceable: **policy checks never query.** They read precomputed sets from
  `AshEnterprise.Security.ActorContext`, and this is where those sets come from.

  It must run **after** `ash_authentication`'s `:load_from_session` /
  `:load_from_bearer` and `:set_actor`, because it needs the user those install.
  With no user it is a no-op, so unauthenticated requests cost nothing.

  It also sets the Ash tenant from the user's organization, so
  `Ash.read(Resource, actor: actor)` is correctly scoped without every call site
  remembering to pass one. Forgetting the tenant is not a visible failure — with
  `global? true` on the multitenancy block it silently reads across tenants,
  which is the worst possible failure mode for a multi-tenant system. Setting it
  centrally, here, is the only reliable place.

  ## Cost

  About five queries. Without it, each of the three grant paths wants a query per
  policy check per row, and policy checks run on every read of every resource.
  """

  @behaviour Plug

  alias AshEnterprise.Security.ActorContext

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    # One correlation id per request, stamped onto every audit event the request
    # produces. Set before the actor check so that even unauthenticated requests
    # that write something (registration, say) are correlated.
    AshEnterprise.Platform.Correlation.start_new()

    case conn.assigns[:current_user] do
      nil ->
        conn

      user ->
        # Not `tenant: user.organization_id`. `User` is `tenant?: false`, so that
        # read is always nil -- it silently overrode nothing and the tenant was
        # never set, which is precisely the failure this moduledoc warns about.
        # `build/2` resolves it through the user's business unit instead.
        context = ActorContext.build(user)
        actor = ActorContext.attach(user, context)

        conn
        |> Plug.Conn.assign(:current_user, actor)
        |> Plug.Conn.assign(:actor_context, context)
        |> Ash.PlugHelpers.set_actor(actor)
        |> Ash.PlugHelpers.set_tenant(context.organization_id)
    end
  end
end
