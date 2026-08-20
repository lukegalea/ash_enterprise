defmodule AshEnterpriseWeb.Bpmn.CatalogLive do
  @moduledoc """
  What this tenant runs: its processes, its decisions, and what starts them.

  Three surfaces in one module because they answer one question in three parts, and because
  the interesting column is the same on each — **where the thing you are running came from**.

  A tenant following a platform baseline and a tenant running its own fork look identical in
  every other listing, and the difference is exactly what an administrator needs to see before
  changing anything. So each row says which it is, and a fork says how far behind the baseline
  it has drifted.

  Deliberately server-rendered. The designer needs a real diagram editor and pays for one; a
  list of keys and versions does not, and adding a second client-side state model to keep in
  step with this one would be a cost with nothing on the other side.
  """

  use AshEnterpriseWeb, :live_view

  require Ash.Query

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.{Binding, Resolver, Trigger}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :drift, %{})}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load(socket, socket.assigns.live_action)}
  end

  @impl true
  def handle_event("customize", %{"key" => key}, socket) do
    kind = socket.assigns.kind

    # The actor is the signed-in administrator, not a system actor: forking is a person's
    # decision and the audit entry should name them. `Resolver.fork/4` is idempotent, so a
    # double-click returns the same draft rather than a second one.
    case Resolver.fork(kind, key, tenant(socket), socket.assigns[:current_user]) do
      {:ok, _draft} ->
        {:noreply,
         socket
         |> put_flash(:info, "Draft created from the baseline. Publish it to switch over.")
         |> push_navigate(to: editor_path(kind, key))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, Exception.message(error))}
    end
  end

  defp editor_path(:process, key), do: ~p"/app/processes/#{key}/designer"
  defp editor_path(:decision, key), do: ~p"/app/decisions/#{key}/editor"

  defp load(socket, :processes),
    do: load_definitions(socket, :process, AshEnterprise.Bpmn.Definition)

  defp load(socket, :decisions),
    do: load_definitions(socket, :decision, AshEnterprise.Decisions.Definition)

  defp load(socket, :triggers) do
    assign(socket, :triggers, read(Trigger, socket))
  end

  defp load_definitions(socket, kind, resource) do
    tenant = tenant(socket)

    # Everything the tenant authored itself, plus every baseline it inherits. A key it has not
    # forked has no row of its own, so listing only the tenant's would show nothing for a
    # tenant running entirely on baselines -- which is the common case and would read as "you
    # have no processes" rather than "you have not changed any".
    own = read(resource, socket)
    baselines = read_platform(resource)
    bindings = Map.new(read(Binding, socket), &{{&1.kind, &1.key}, &1})

    rows =
      (own ++ baselines)
      |> Enum.group_by(& &1.key)
      |> Enum.map(fn {key, definitions} ->
        binding = bindings[{kind, key}]
        active = active_definition(definitions, binding, own)

        %{
          key: key,
          version: active && active.version,
          source: if(binding, do: binding.source, else: :platform),
          forked_from: binding && binding.forked_from_version,
          status: active && active.status
        }
      end)
      |> Enum.sort_by(& &1.key)

    socket
    |> assign(:rows, rows)
    |> assign(:kind, kind)
    |> assign(:drift, Map.new(Resolver.drift(tenant), &{{&1.kind, &1.key}, &1}))
  end

  defp active_definition(definitions, %{source: :tenant, target_id: id}, _own),
    do: Enum.find(definitions, &(&1.id == id))

  defp active_definition(definitions, _binding, _own) do
    definitions
    |> Enum.filter(&(&1.status == :published))
    |> Enum.max_by(& &1.version, fn -> List.first(definitions) end)
  end

  defp read(resource, socket) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant(socket))
  end

  defp read_platform(resource) do
    case Resolver.platform_tenant() do
      nil ->
        []

      platform ->
        resource
        |> Ash.Query.for_read(:read)
        |> Ash.read!(actor: SystemActor.process(), tenant: platform)
    end
  end

  defp tenant(socket), do: socket.assigns[:current_tenant]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]} width="max-w-7xl">
      <div class="space-y-6">
        <h1 class="text-2xl font-semibold">{title(@live_action)}</h1>
        <p class="max-w-3xl text-sm opacity-70">{blurb(@live_action)}</p>

        <%= if @live_action == :triggers do %>
          <table class="table table-zebra" id="triggers-table">
            <thead>
              <tr>
                <th>Key</th>
                <th>Watches</th>
                <th>Guard</th>
                <th>Starts</th>
                <th>State</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={t <- @triggers} id={"trigger-#{t.id}"}>
                <td class="font-mono text-xs">
                  {t.key} <span class="opacity-50">v{t.version}</span>
                </td>
                <td class="font-mono text-xs">
                  {short(t.match_resource)}<span :if={t.match_action} class="opacity-60">.{t.match_action}</span>
                </td>
                <td class="font-mono text-xs opacity-70">{t.guard_feel || "—"}</td>
                <td class="font-mono text-xs">{t.decision_key || t.process_key}</td>
                <td>
                  <span class={["badge badge-sm", state_class(t)]}>{state_label(t)}</span>
                </td>
              </tr>
            </tbody>
          </table>
        <% else %>
          <table class="table table-zebra" id="catalog-table">
            <thead>
              <tr>
                <th>Key</th>
                <th>Running</th>
                <th>Source</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"catalog-#{row.key}"}>
                <td class="font-mono text-xs">{row.key}</td>
                <td>v{row.version} <span class="opacity-50 text-xs">{row.status}</span></td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    if(row.source == :tenant, do: "badge-warning", else: "badge-ghost")
                  ]}>
                    {if row.source == :tenant, do: "customized", else: "platform baseline"}
                  </span>
                  <%!-- The whole reason this page exists: a fork that has fallen behind is
                        invisible everywhere else, and this is where somebody decides whether
                        to care. Deliberately not a merge button -- the two documents have
                        diverged and reconciling them is the round-tripping problem again. --%>
                  <span :if={drift = @drift[{@kind, row.key}]} class="ml-2 text-xs opacity-70">
                    <%= if drift.behind_by && drift.behind_by > 0 do %>
                      forked from platform v{drift.forked_from_version} · platform is now v{drift.platform_version}
                    <% end %>
                  </span>
                </td>
                <td class="space-x-1 text-right">
                  <%!-- Customizing is an explicit act, not a side effect of opening an editor.
                        Both editors create a draft on first visit if none exists, seeded from a
                        blank template -- which is right for a key nobody has ever published and
                        wrong here, where the answer should be a copy of the baseline. So the
                        fork happens on this button, and the editor is only ever opened on a
                        draft that already exists.

                        It also keeps the default honest. Absence of a binding means "follow the
                        baseline"; a design where merely looking at a decision forked it would
                        turn every visit into a customization. --%>
                  <button
                    :if={row.source == :platform}
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="customize"
                    phx-value-key={row.key}
                  >
                    Customize
                  </button>
                  <.link
                    :if={@kind == :process and row.source == :tenant}
                    navigate={~p"/app/processes/#{row.key}/designer"}
                    class="btn btn-ghost btn-xs"
                  >
                    Open designer
                  </.link>
                  <.link
                    :if={@kind == :decision and row.source == :tenant}
                    navigate={~p"/app/decisions/#{row.key}/editor"}
                    class="btn btn-ghost btn-xs"
                  >
                    Open editor
                  </.link>
                  <%!-- A baseline is readable but not editable from here: publishing into the
                        platform organization is `mix ash_enterprise.bpmn.publish` and nothing
                        else. See ADR 0029. --%>
                  <.link
                    :if={@kind == :process and row.source == :platform}
                    navigate={~p"/app/processes/#{row.key}/designer"}
                    class="btn btn-ghost btn-xs"
                  >
                    View
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp title(:processes), do: "Processes"
  defp title(:decisions), do: "Decisions"
  defp title(:triggers), do: "Triggers"

  defp blurb(:processes),
    do:
      "Every process this tenant can run. A baseline is the platform's, published from a reviewed file; a customization is this tenant's own, authored in the designer."

  defp blurb(:decisions),
    do:
      "DMN decisions a process routes on. Unlike a process, a decision is resolved when it is asked rather than pinned for the life of an instance -- changing a rule takes effect without restarting what is already running."

  defp blurb(:triggers),
    do:
      "What starts a process. A trigger matches an audited write, checks a FEEL guard, and either names a process or asks a decision which one to start."

  defp short(resource), do: AshEnterprise.Process.Trigger.ResourceName.short(resource || "")

  defp state_label(%{status: :published, enabled: true}), do: "live"
  defp state_label(%{status: :published, enabled: false}), do: "disabled"
  defp state_label(%{status: status}), do: to_string(status)

  defp state_class(%{status: :published, enabled: true}), do: "badge-success"
  defp state_class(%{status: :published, enabled: false}), do: "badge-warning"
  defp state_class(_), do: "badge-ghost"
end
