defmodule AshEnterpriseWeb.LegacyAgentLive do
  @moduledoc "Authenticated console for the legacy-vocabulary helper agent."

  use AshEnterpriseWeb, :live_view

  on_mount({AshEnterpriseWeb.LiveUserAuth, :live_user_required})

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <AshEnterpriseWeb.Layouts.app flash={@flash} width="max-w-3xl">
      <div class="space-y-6">
        <header>
          <h1 class="text-2xl font-semibold">Legacy helper</h1>
          <p class="text-base-content/70 text-sm">
            This helper exposes only read actions named in the legacy vocabulary.
          </p>
        </header>
        <ul class="list-disc pl-6">
          <li :for={tool <- legacy_tools()}>{tool}</li>
        </ul>
        <p class="text-base-content/70 text-sm">
          Every action runs with the signed-in actor through the compatibility-view policies.
        </p>
      </div>
    </AshEnterpriseWeb.Layouts.app>
    """
  end

  defp legacy_tools do
    AshAi.Info.tools(AshEnterprise.LegacyAgent)
    |> Enum.map(&to_string(&1.name))
    |> Enum.sort()
  end
end
