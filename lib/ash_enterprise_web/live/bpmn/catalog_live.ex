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

  alias AshEnterprise.Bpmn.Subscription
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.{Binding, DefinitionLoader, Resolver}
  alias AshEnterpriseWeb.Bpmn.Baselines

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
        {:noreply, put_flash(socket, :error, Baselines.fork_error(error))}
    end
  end

  defp editor_path(:process, key), do: ~p"/app/processes/#{key}/designer"
  defp editor_path(:decision, key), do: ~p"/app/decisions/#{key}/editor"

  defp load(socket, :processes),
    do: load_definitions(socket, :process, AshEnterprise.Bpmn.Definition)

  defp load(socket, :decisions),
    do: load_definitions(socket, :decision, AshEnterprise.Decisions.Definition)

  defp load(socket, :triggers) do
    assign(socket, :triggers, read(Subscription, socket))
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
    |> assign(:instances, if(kind == :process, do: running_instances(socket), else: []))
    |> assign(:drift, Map.new(Resolver.drift(tenant), &{{&1.kind, &1.key}, &1}))
  end

  # What is actually running, and the route to each run's flight view.
  #
  # Before this, `/app/instances/:id` was reachonly by typing a UUID: no screen linked to it,
  # so the one surface that shows a diagram with live tokens on it was effectively unreachable.
  # A list of keys and versions answers "what could run here"; this answers "what is running",
  # which is the question someone on call actually has.
  #
  # Read as the signed-in person, so the list holds only runs they may open on their
  # flight view (a role grant on instances, or a step of the run waiting on them).
  defp running_instances(socket) do
    tenant = tenant(socket)

    instances =
      AshEnterprise.Bpmn.Instance
      |> Ash.Query.for_read(:running_now)
      |> Ash.Query.limit(10)
      |> Ash.read!(actor: socket.assigns[:current_user], tenant: tenant)

    # An instance carries `definition_id`, not `definition_key` -- deliberately, because the
    # key is not what it is pinned to. Resolving the key therefore means reading the
    # definition, and the definition may be the platform organization's rather than this
    # tenant's, which is exactly what `DefinitionLoader` exists to handle. Reading it here with
    # a plain tenant-scoped query would show a blank key for every instance running a baseline
    # -- which is most of them.
    Enum.map(instances, fn instance ->
      key =
        case DefinitionLoader.load(
               AshEnterprise.Bpmn.Definition,
               instance.definition_id,
               instance,
               %{tenant: tenant}
             ) do
          {:ok, definition} -> definition.key
          {:error, _} -> nil
        end

      %{instance: instance, key: key}
    end)
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
    <Layouts.app
      flash={@flash}
      page={assigns[:page]}
      current_scope={assigns[:current_scope]}
      width="max-w-7xl"
    >
      <div class="space-y-6">
        <%= if @live_action == :triggers do %>
          <div class="overflow-auto rounded-base border-2 border-border shadow-shadow">
            <table class={table_class()} id="triggers-table">
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
                    {t.key} <span class="text-foreground/70">v{t.version}</span>
                  </td>
                  <td class="font-mono text-xs">
                    {short(t.match_resource)}<span :if={t.match_action} class="text-foreground/70">.{t.match_action}</span>
                  </td>
                  <td class="font-mono text-xs text-foreground/70">{t.guard_feel || "—"}</td>
                  <td class="font-mono text-xs">{t.decision_key || t.process_key}</td>
                  <td>
                    <.badge tone={state_tone(t)}>{state_label(t)}</.badge>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% else %>
          <div class="overflow-auto rounded-base border-2 border-border shadow-shadow">
            <table class={table_class()} id="catalog-table">
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
                  <td>v{row.version} <span class="text-foreground/70 text-xs">{row.status}</span></td>
                  <td>
                    <.badge tone={if(row.source == :tenant, do: "yellow")}>
                      {if row.source == :tenant, do: "customized", else: "platform baseline"}
                    </.badge>
                    <%!-- The whole reason this page exists: a fork that has fallen behind is
                        invisible everywhere else, and this is where somebody decides whether
                        to care. Deliberately not a merge button -- the two documents have
                        diverged and reconciling them is the round-tripping problem again. --%>
                    <span
                      :if={drift = @drift[{@kind, row.key}]}
                      class="ml-2 text-xs text-foreground/70"
                    >
                      <%= if drift.behind_by && drift.behind_by > 0 do %>
                        forked from platform v{drift.forked_from_version} · platform is now v{drift.platform_version}
                      <% end %>
                    </span>
                  </td>
                  <td class="space-x-1 text-right">
                    <%!-- Customizing is an explicit act, not a side effect of opening an editor.
                        Opening either editor on a baseline key writes nothing and shows the
                        baseline read-only (`AshEnterpriseWeb.Bpmn.Baselines`); the fork happens
                        here or on the editor's own Customize button, which make the same call.

                        It also keeps the default honest. Absence of a binding means "follow the
                        baseline"; a design where merely looking at a decision forked it would
                        turn every visit into a customization. --%>
                    <.button
                      :if={@kind == :process and flight_path(row.key)}
                      navigate={flight_path(row.key)}
                      variant="ghost"
                      size="xs"
                      id={"flight-#{row.key}"}
                    >
                      In flight
                    </.button>
                    <.button
                      :if={row.source == :platform}
                      type="button"
                      phx-click="customize"
                      phx-value-key={row.key}
                      variant="ghost"
                      size="xs"
                    >
                      Customize
                    </.button>
                    <.button
                      :if={@kind == :process and row.source == :tenant}
                      navigate={~p"/app/processes/#{row.key}/designer"}
                      variant="ghost"
                      size="xs"
                    >
                      Open designer
                    </.button>
                    <.button
                      :if={@kind == :decision and row.source == :tenant}
                      navigate={~p"/app/decisions/#{row.key}/editor"}
                      variant="ghost"
                      size="xs"
                    >
                      Open editor
                    </.button>
                    <%!-- A baseline is readable but not editable from here: publishing into the
                        platform organization is `mix ash_enterprise.bpmn.publish` and nothing
                        else. See ADR 0029. --%>
                    <.button
                      :if={@kind == :process and row.source == :platform}
                      navigate={~p"/app/processes/#{row.key}/designer"}
                      variant="ghost"
                      size="xs"
                    >
                      View
                    </.button>
                    <.button
                      :if={@kind == :decision and row.source == :platform}
                      navigate={~p"/app/decisions/#{row.key}/editor"}
                      variant="ghost"
                      size="xs"
                    >
                      View
                    </.button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Running instances. See `running_instances/1`: without this the instance viewer
                had no inbound link from anywhere in the application. --%>
          <div :if={@kind == :process} class="space-y-2">
            <h2 class="text-lg font-heading">Running now</h2>
            <p class="max-w-3xl text-sm text-foreground/70">
              Each one is pinned to the definition version it started on and keeps running it,
              so rebinding a key never migrates work that is already in flight.
            </p>

            <p :if={@instances == []} class="text-sm text-foreground/70" id="no-instances">
              Nothing running. `mix ash_enterprise.bpmn.setup` leaves some behind.
            </p>

            <div
              :if={@instances != []}
              class="overflow-auto rounded-base border-2 border-border shadow-shadow"
            >
              <table class={table_class()} id="instances-table">
                <thead>
                  <tr>
                    <th>Process</th>
                    <th>Started</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @instances} id={"instance-#{row.instance.id}"}>
                    <td class="font-mono text-xs">{row.key || "(definition not found)"}</td>
                    <td class="text-xs text-foreground/70">{row.instance.created_on}</td>
                    <td class="space-x-1 text-right">
                      <.button
                        href={~p"/app/r/flight/#{row.instance.id}"}
                        variant="ghost"
                        size="xs"
                        id={"flight-#{row.instance.id}"}
                      >
                        Flight view
                      </.button>
                      <.button
                        navigate={~p"/app/instances/#{row.instance.id}"}
                        variant="ghost"
                        size="xs"
                      >
                        BPMN diagram
                      </.button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # The processes with a flight view of every run (`AshEnterpriseWeb.FlightLive`).
  defp flight_path("morning.brief"), do: ~p"/app/flights/briefs"
  defp flight_path("mdm.steward_review"), do: ~p"/app/flights/stewardship"
  defp flight_path(_key), do: nil

  defp short(resource),
    do: AshBpmn.Resources.Subscription.ResourceName.short(resource || "")

  defp state_label(%{status: :published, enabled: true}), do: "live"
  defp state_label(%{status: :published, enabled: false}), do: "disabled"
  defp state_label(%{status: status}), do: to_string(status)

  defp state_tone(%{status: :published, enabled: true}), do: "green"
  defp state_tone(%{status: :published, enabled: false}), do: "yellow"
  defp state_tone(_), do: "neutral"
end
