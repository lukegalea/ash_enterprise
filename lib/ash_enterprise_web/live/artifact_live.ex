defmodule AshEnterpriseWeb.ArtifactLive do
  @moduledoc """
  `/app/artifacts`: the versioned things people author, review and release, one page for
  every type in the artifact registry (`AshEnterprise.Artifacts`).

    * `:index` lists each type the viewer's doors admit, its newest versions first.
    * `:show` (`/app/artifacts/:type/:id`) is one version: its header
      (`AshEnterpriseWeb.ArtifactComponents.artifact_header/1`), its validation, and its
      semantic diff against the version before it, or against `?from=<id>`. Opened with
      `?run=<id>` (from a run), the header says whether this is the version that run used.

  Nothing on the page is specific to a type: everything comes from the type's registry
  entry. Read-only, read as the viewer in `handle_params/3`; there are no events.
  """

  use AshEnterpriseWeb, :live_view

  alias AshEnterprise.Artifacts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("artifacts", "Artifacts"),
       types: [],
       artifact: nil,
       record: nil,
       header: nil,
       used_by: nil,
       other_version_path: nil,
       validation: nil,
       diff: nil,
       from_label: nil,
       versions: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, load(socket, params)}

  defp load(%{assigns: %{live_action: :show}} = socket, %{"type" => type, "id" => id} = params) do
    actor = socket.assigns.current_user

    with %{} = entry <- Artifacts.fetch(type),
         {:ok, record} <- Artifacts.get(entry, id, actor) do
      from = from(entry, record, params["from"], actor)
      used_by = Artifacts.used_by(entry, record, params["run"], actor)

      assign(socket,
        artifact: entry,
        record: record,
        header: Artifacts.header(entry, record, actor),
        used_by: used_by,
        other_version_path: other_version_path(entry, used_by),
        validation: Artifacts.validation(entry, record),
        diff: Artifacts.diff(entry, from, record, actor: actor, tenant: tenant(actor)),
        from_label: from_label(entry, from),
        versions: versions(entry, record, actor),
        page_title: Artifacts.translate(entry.label)
      )
    else
      _unknown_or_unreadable ->
        socket
        |> assign(artifact: nil, record: nil)
        |> put_flash(:error, dgettext("artifacts", "No version you can read has this address."))
    end
  end

  defp load(socket, _params) do
    assign(socket, types: Artifacts.discover(socket.assigns.current_user))
  end

  # The version to compare with: the one asked for, else the one before.
  defp from(entry, record, nil, actor), do: Artifacts.previous(entry, record, actor)

  defp from(entry, _record, id, actor) do
    case Artifacts.get(entry, id, actor) do
      {:ok, record} -> {:ok, record}
      :unreadable -> {:unreadable, :from}
    end
  end

  defp from_label(entry, {:ok, record}) do
    case entry.version && Map.get(record, entry.version) do
      nil -> to_string(Map.get(record, entry.identity))
      version -> dgettext("artifacts", "version %{version}", version: version)
    end
  end

  defp from_label(_entry, _state), do: nil

  defp other_version_path(%{runs: {_resource, attribute}} = entry, {:other, run}) do
    case Map.get(run, attribute) do
      nil -> nil
      id -> Artifacts.path(entry, id)
    end
  end

  defp other_version_path(_entry, _used_by), do: nil

  # Other versions to compare with: the same artifact's, or, for a type that keeps no
  # versions, the type's.
  defp versions(entry, record, actor) do
    case Artifacts.list(entry, actor) do
      {:ok, records} ->
        same = Map.get(record, entry.identity)

        Enum.filter(records, fn other ->
          other.id != record.id and
            (is_nil(entry.lineage) or Map.get(other, entry.identity) == same)
        end)

      {:error, _error} ->
        []
    end
  end

  defp tenant(actor), do: AshEnterprise.Security.ActorContext.tenant(actor)

  # --- rendering ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-5xl">
      <%= if @live_action == :show do %>
        <.version
          :if={@record}
          artifact={@artifact}
          record={@record}
          header={@header}
          used_by={@used_by}
          other_version_path={@other_version_path}
          validation={@validation}
          diff={@diff}
          from_label={@from_label}
          versions={@versions}
        />
        <.link navigate={~p"/app/artifacts"} class="text-sm underline" id="back-to-artifacts">
          {dgettext("artifacts", "Every artifact")}
        </.link>
      <% else %>
        <.index types={@types} />
      <% end %>
    </Layouts.app>
    """
  end

  attr :types, :list, required: true

  defp index(assigns) do
    ~H"""
    <h1 class="font-heading text-2xl">{dgettext("artifacts", "Artifacts")}</h1>
    <p class="text-sm text-foreground/70">
      {dgettext(
        "artifacts",
        "The versions of what is authored here: agents, processes, decisions, mappings, suites, releases, rule sets and saved surfaces. Open one to see what it is, whether it checks out and what changed."
      )}
    </p>
    <section
      :for={%{artifact: artifact, items: items} <- @types}
      id={"artifacts-#{artifact.type}"}
      class="mt-6 space-y-2"
    >
      <h2 class="font-heading text-lg">{Artifacts.translate(artifact.label)}</h2>
      <.items artifact={artifact} items={items} />
    </section>
    """
  end

  attr :artifact, :any, required: true
  attr :items, :any, required: true

  defp items(%{items: {:error, _error}} = assigns) do
    ~H"""
    <.status_message id={"artifacts-#{@artifact.type}-unreadable"} kind={:error} role="alert">
      {dgettext("artifacts", "These could not be read.")}
    </.status_message>
    """
  end

  defp items(%{items: {:ok, []}} = assigns) do
    ~H"""
    <p id={"artifacts-#{@artifact.type}-none"} class="text-sm text-foreground/60">
      {dgettext("artifacts", "None you can read.")}
    </p>
    """
  end

  defp items(%{items: {:ok, records}} = assigns) do
    assigns = assign(assigns, :records, records)

    ~H"""
    <table id={"artifacts-#{@artifact.type}-rows"} class="w-full text-left text-sm">
      <thead>
        <tr class="border-b-2 border-border">
          <th class="py-1 pr-3">{dgettext("artifacts", "Name")}</th>
          <th class="py-1 pr-3">{dgettext("artifacts", "Version")}</th>
          <th class="py-1 pr-3">{dgettext("artifacts", "Lifecycle")}</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={record <- @records}
          id={"artifact-#{@artifact.type}-#{record.id}"}
          data-lifecycle={lifecycle(@artifact, record)}
          class="border-b border-border/30"
        >
          <td class="py-1 pr-3">
            <.link navigate={Artifacts.path(@artifact, record.id)} class="underline break-all">
              {Map.get(record, @artifact.identity)}
            </.link>
          </td>
          <td class="py-1 pr-3 font-mono text-xs">
            {@artifact.version && Map.get(record, @artifact.version)}
          </td>
          <td class="py-1 pr-3 font-mono text-xs">
            {lifecycle_state(@artifact, record)}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :artifact, :any, required: true
  attr :record, :any, required: true
  attr :header, :map, required: true
  attr :used_by, :any, required: true
  attr :other_version_path, :string, default: nil
  attr :validation, :any, required: true
  attr :diff, :any, required: true
  attr :from_label, :string, default: nil
  attr :versions, :list, required: true

  defp version(assigns) do
    ~H"""
    <article id={"artifact-#{@artifact.type}-#{@record.id}"} class="space-y-6">
      <.artifact_header
        header={@header}
        used_by={@used_by}
        other_version_path={@other_version_path}
      />
      <.artifact_validation validation={@validation} />
      <.artifact_diff
        state={@diff}
        aspects={Artifacts.aspects(@artifact)}
        from_label={@from_label}
      />
      <section :if={@versions != []} id="artifact-versions" class="space-y-2">
        <h3 class="font-heading">{dgettext("artifacts", "Compare with another version")}</h3>
        <ul class="text-sm">
          <li :for={other <- @versions}>
            <.link
              id={"compare-#{other.id}"}
              patch={Artifacts.path(@artifact, @record.id) <> "?from=" <> other.id}
              class="underline"
            >
              {Map.get(other, @artifact.identity)}
              <span :if={@artifact.version} class="font-mono text-xs">
                {dgettext("artifacts", "version %{version}",
                  version: Map.get(other, @artifact.version)
                )}
              </span>
            </.link>
          </li>
        </ul>
      </section>
    </article>
    """
  end

  defp lifecycle(artifact, record) do
    case Artifacts.lifecycle(artifact, record) do
      nil -> "none"
      {_state, class} -> class
    end
  end

  defp lifecycle_state(artifact, record) do
    case Artifacts.lifecycle(artifact, record) do
      nil -> nil
      {state, _class} -> state
    end
  end
end
