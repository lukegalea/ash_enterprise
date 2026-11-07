defmodule AshEnterpriseWeb.ModelProfilesLive do
  @moduledoc """
  `/app/models`: the model profiles (`AshEnterprise.AI.ModelProfile`), each with the
  model it runs, what it may be used for, whether it is known to answer, and what it is
  restricted from.

  Read as the signed-in person in `handle_params/3` (Iron Law #1); the page has no
  events, so it acts on nothing. Readiness is shown as recorded: a profile whose
  readiness is unknown is shown as unknown, never as ready.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.AI
  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Model profiles", profiles: [], error?: false)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    actor = socket.assigns.current_user

    case AI.model_profiles(actor: actor, tenant: ActorContext.tenant(actor)) do
      {:ok, profiles} -> {:noreply, assign(socket, profiles: profiles, error?: false)}
      {:error, _error} -> {:noreply, assign(socket, profiles: [], error?: true)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-4xl">
      <p :if={@error?} id="model-profiles-error" class="text-sm text-red">
        The model profiles could not be read as you, so none is shown. That is not the same
        as there being none.
      </p>
      <section
        :for={profile <- @profiles}
        id={"profile-#{profile.key}"}
        data-readiness={profile.readiness}
        data-ready={to_string(profile.ready)}
        class="space-y-3 border-2 border-border p-4"
      >
        <header class="flex flex-wrap items-baseline justify-between gap-2">
          <h2 class="font-heading text-lg">{profile.label}</h2>
          <span
            id={"profile-#{profile.key}-readiness"}
            class={["px-2 py-0.5 text-xs font-heading", readiness_class(profile.readiness)]}
          >
            {readiness_label(profile.readiness)}
          </span>
        </header>
        <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
          <dt class="opacity-70">Profile</dt>
          <dd class="font-mono">{profile.key}</dd>
          <dt class="opacity-70">Model</dt>
          <dd>{profile.model || "none configured"}</dd>
          <dt class="opacity-70">Zone</dt>
          <dd>{profile.zone || "unknown"}</dd>
        </dl>
        <p id={"profile-#{profile.key}-note"} class="text-sm">{profile.readiness_note}</p>
        <div>
          <h3 class="font-heading text-sm">Permitted use</h3>
          <ul id={"profile-#{profile.key}-use"} class="list-disc ps-5 text-sm">
            <li :for={use <- profile.permitted_use}>{use}</li>
          </ul>
        </div>
        <div>
          <h3 class="font-heading text-sm">Restrictions</h3>
          <ul id={"profile-#{profile.key}-restrictions"} class="list-disc ps-5 text-sm">
            <li :for={restriction <- profile.restrictions}>{restriction}</li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp readiness_label(:ready), do: "Ready"
  defp readiness_label(:not_ready), do: "Not ready"
  defp readiness_label(:not_configured), do: "Not configured"
  defp readiness_label(_unknown), do: "Readiness unknown"

  defp readiness_class(:ready), do: "bg-green text-on-vivid"
  defp readiness_class(:not_ready), do: "bg-red text-on-vivid"
  defp readiness_class(_other), do: "bg-yellow text-on-vivid"
end
