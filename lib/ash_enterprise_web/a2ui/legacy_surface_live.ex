defmodule AshEnterpriseWeb.A2uiLive.LegacySurface do
  @moduledoc false

  defmacro __using__(opts) do
    ui = Keyword.fetch!(opts, :ui)

    quote do
      use AshA2ui.LiveRenderer,
        ui: unquote(ui),
        actor_fn: &__MODULE__.actor/1,
        tenant_fn: &__MODULE__.tenant/1

      alias AshEnterprise.Security.ActorContext
      alias AshEnterpriseWeb.A2uiLive.Chrome

      def actor(socket), do: socket.assigns[:current_user]
      def tenant(socket), do: ActorContext.tenant(socket.assigns[:current_user])
      def render(assigns), do: Chrome.page(assigns)
    end
  end
end

defmodule AshEnterpriseWeb.A2uiLive.LegacyParties do
  use AshEnterpriseWeb.A2uiLive.LegacySurface, ui: AshEnterpriseWeb.A2ui.LegacyPartyUI
end

defmodule AshEnterpriseWeb.A2uiLive.LegacyVendorParties do
  use AshEnterpriseWeb.A2uiLive.LegacySurface, ui: AshEnterpriseWeb.A2ui.LegacyVendorPartyUI
end

defmodule AshEnterpriseWeb.A2uiLive.LegacyEnterpriseParties do
  use AshEnterpriseWeb.A2uiLive.LegacySurface, ui: AshEnterpriseWeb.A2ui.LegacyEnterprisePartyUI
end

defmodule AshEnterpriseWeb.A2uiLive.LegacyContractingProcesses do
  use AshEnterpriseWeb.A2uiLive.LegacySurface,
    ui: AshEnterpriseWeb.A2ui.LegacyContractingProcessUI
end

defmodule AshEnterpriseWeb.A2uiLive.LegacyPartyRoles do
  use AshEnterpriseWeb.A2uiLive.LegacySurface, ui: AshEnterpriseWeb.A2ui.LegacyPartyRoleUI
end

defmodule AshEnterpriseWeb.A2uiLive.LegacyContracts do
  use AshEnterpriseWeb.A2uiLive.LegacySurface, ui: AshEnterpriseWeb.A2ui.LegacyContractUI
end

defmodule AshEnterpriseWeb.A2uiLive.LegacyContractLines do
  use AshEnterpriseWeb.A2uiLive.LegacySurface, ui: AshEnterpriseWeb.A2ui.LegacyContractLineUI
end

defmodule AshEnterpriseWeb.A2uiLive.LegacyCommitments do
  use AshEnterpriseWeb.A2uiLive.LegacySurface, ui: AshEnterpriseWeb.A2ui.LegacyCommitmentUI
end
