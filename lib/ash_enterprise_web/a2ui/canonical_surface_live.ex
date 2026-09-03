defmodule AshEnterpriseWeb.A2uiLive.CanonicalSurface do
  @moduledoc false

  defmacro __using__(opts) do
    ui = Keyword.fetch!(opts, :ui)

    quote do
      use AshA2ui.LiveRenderer,
        ui: unquote(ui),
        actor_fn: &__MODULE__.actor/1,
        tenant_fn: &__MODULE__.tenant/1,
        pubsub: [
          module: AshEnterprise.PubSub,
          topics: AshEnterpriseWeb.A2ui.Surfaces.topics(unquote(ui))
        ]

      alias AshEnterprise.Security.ActorContext
      alias AshEnterpriseWeb.A2uiLive.Chrome

      def actor(socket), do: socket.assigns[:current_user]
      def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])
      def render(assigns), do: Chrome.page(assigns)
    end
  end
end

defmodule AshEnterpriseWeb.A2uiLive.CanonicalParties do
  use AshEnterpriseWeb.A2uiLive.CanonicalSurface, ui: AshEnterpriseWeb.A2ui.CanonicalPartyUI
end

defmodule AshEnterpriseWeb.A2uiLive.CanonicalContracts do
  use AshEnterpriseWeb.A2uiLive.CanonicalSurface, ui: AshEnterpriseWeb.A2ui.CanonicalContractUI
end

defmodule AshEnterpriseWeb.A2uiLive.CanonicalCommitments do
  use AshEnterpriseWeb.A2uiLive.CanonicalSurface,
    ui: AshEnterpriseWeb.A2ui.CanonicalCommitmentUI
end
