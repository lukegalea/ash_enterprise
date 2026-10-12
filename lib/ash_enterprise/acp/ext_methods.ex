defmodule AshEnterprise.Acp.ExtMethods do
  @moduledoc """
  `AshAcp.ExtMethods` for the dogfood ACP server: the three `ash` extension
  methods (`priv/acp_schema/ash_ext.json` in ash_acp), so a client such as
  amber can list surfaces, open one directly — a record selected, no model
  turn — and act on it, all as the session's actor.

  | Method | What it does |
  |---|---|
  | `_ash/surfaces/list` | The registry's A2UI surfaces whose door is open for the actor and whose resource they may read (`Ash.can?`) |
  | `_ash/surface/open` | Builds the surface (`AshA2ui.Info.build_surface/2`); with a `recordId`, the record selected through `AshEnterprise.Surfaces.Records` (door, authorized read, context selection — "not found" for anything else). Recorded in the session store, so `session/load` re-emits it, with a one-line `opened <surface>` transcript entry |
  | `_a2ui/action` | Runs the A2UI action through `AshA2ui.ActionHandler` as the session actor. Reads (query, select, search, report, export) run at once; writes (`submit_form`, `invoke`, `prompt`, `edit_cell`) are consequential and ask first (`{:request_permission, spec}` → `AshEnterprise.Acp.Approvals`) |

  Nothing here bypasses policy: every build and action runs with the actor
  and `authorize?: true`, and a client-supplied surface or record id is only a
  request — the same doors and reads the web applies decide what it gets.
  Shred is unreachable: the erasure surface's ACP UI
  (`AshEnterpriseWeb.A2ui.ErasureReadOnlyUI`) carries no action that could ask
  for it.
  """

  @behaviour AshAcp.ExtMethods

  alias AshEnterprise.Acp
  alias AshEnterprise.Acp.SessionStore
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.Records

  @list "_ash/surfaces/list"
  @open "_ash/surface/open"
  @action "_a2ui/action"

  # A2UI client actions that write. Everything else the handler accepts reads.
  @writes ~w(submit_form invoke prompt edit_cell)

  @impl true
  def methods, do: [@list, @open, @action]

  @impl true
  def capabilities(ctx) do
    case actor(ctx) do
      nil -> %{}
      actor -> %{"surfaces" => entries(actor)}
    end
  rescue
    # The handshake must not depend on an optional index (an unseeded node has
    # no operator to list surfaces for).
    _error -> %{}
  end

  @impl true
  def handle(@list, _params, ctx), do: {:ok, %{"surfaces" => entries(actor(ctx))}}

  def handle(@open, %{"surface" => surface} = params, %{session: session} = ctx)
      when is_binary(surface) and not is_nil(session) do
    actor = actor(ctx)

    case open(surface, params["recordId"], params["query"], actor) do
      {:ok, entry, ui, opts} ->
        messages = build(ui, opts, actor)
        SessionStore.put_surface(ctx.session_id, {ui, opts})
        SessionStore.append_message(session, :agent, "opened #{entry.label}")
        {:ok, %{"surfaceId" => surface_id(messages, ui), "a2ui" => messages}}

      {:error, code, message} ->
        {:error, code, message}
    end
  end

  def handle(@open, _params, _ctx),
    do: {:error, -32_602, "#{@open} needs a sessionId and a surface"}

  def handle(@action, %{"surfaceId" => surface_id, "action" => action}, %{session: session} = ctx)
      when is_binary(surface_id) and is_map(action) and not is_nil(session) do
    actor = actor(ctx)

    with {:ok, entry, ui} <- acting_surface(surface_id, actor),
         {:ok, name, context} <- parse_action(action) do
      act(entry, ui, action, name, context, actor, ctx.permission)
    end
  end

  def handle(@action, _params, _ctx),
    do: {:error, -32_602, "#{@action} needs a sessionId, a surfaceId and an action"}

  def handle(method, _params, _ctx), do: {:error, -32_601, "unknown method #{method}"}

  # -- _ash/surfaces/list -------------------------------------------------------

  @doc """
  The surfaces `actor` may open over ACP, as `SurfaceEntry` maps: the
  registry's surfaces with an A2UI UI, behind an open door, over a resource
  the actor may read.
  """
  @spec entries(term()) :: [map()]
  def entries(nil), do: []

  def entries(actor) do
    groups = Map.new(Surfaces.groups(), &{&1.key, &1.label})

    for surface <- Surfaces.visible(actor),
        Surfaces.acp_ui(surface),
        readable?(surface, actor) do
      %{
        "id" => Atom.to_string(surface.key),
        "title" => surface.label,
        "description" => surface.blurb,
        "group" => Map.fetch!(groups, surface.group),
        # Every surface opens as a list; these also open one record.
        "recordScoped" => false,
        "records" => not is_nil(surface.context)
      }
    end
  end

  defp readable?(%{resource: nil}, _actor), do: true

  defp readable?(%{resource: resource}, actor) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      %{name: read} -> Ash.can?({resource, read}, actor, tenant: ActorContext.tenant(actor))
      nil -> false
    end
  rescue
    _error -> false
  end

  # -- _ash/surface/open --------------------------------------------------------

  defp open(key, record_id, query, actor) when is_binary(record_id) and record_id != "" do
    case Records.open(key, record_id, actor) do
      {:ok, %{surface: entry, context_state: state}} ->
        {:ok, entry, Surfaces.acp_ui(entry), [context_state: state] ++ query_opts(query)}

      {:error, {:no_detail, _entry}} ->
        open(key, nil, query, actor)

      {:error, error} ->
        open_error(error)
    end
  end

  defp open(key, _no_record, query, actor) do
    case Records.surface_for(key, actor) do
      {:ok, entry} ->
        case Surfaces.acp_ui(entry) do
          nil ->
            {:error, -32_602,
             "#{entry.label} has no surface to show here; it is at #{entry.path}"}

          ui ->
            {:ok, entry, ui, query_opts(query)}
        end

      {:error, error} ->
        open_error(error)
    end
  end

  defp open_error({:no_surface, _key} = error), do: {:error, -32_602, Records.message(error)}
  defp open_error(error), do: {:error, -32_002, Records.message(error)}

  defp query_opts(query) when is_map(query) and map_size(query) > 0, do: [query_state: query]
  defp query_opts(_none), do: []

  defp build(ui, opts, actor) do
    AshA2ui.Info.build_surface(ui, [actor: actor, tenant: ActorContext.tenant(actor)] ++ opts)
  end

  defp surface_id(messages, ui) do
    Enum.find_value(messages, fn
      %{"createSurface" => %{"surfaceId" => id}} -> id
      _other -> nil
    end) || Macro.underscore(inspect(ui))
  end

  # -- _a2ui/action -------------------------------------------------------------

  # The surface an action names, found in the registry by its A2UI surface id
  # and behind its door: a client cannot act on a surface it could not open.
  defp acting_surface(surface_id, actor) do
    found =
      Enum.find_value(Surfaces.all(), fn entry ->
        ui = Surfaces.acp_ui(entry)

        if ui && AshA2ui.ResolvedView.resolve(ui, []).surface_id == surface_id,
          do: {entry, ui}
      end)

    case found do
      {entry, ui} ->
        if Surfaces.open?(entry, actor),
          do: {:ok, entry, ui},
          else:
            {:error, -32_002, Records.message({:door_closed, "#{entry.label} is closed to you."})}

      nil ->
        {:error, -32_602, "unknown surfaceId #{inspect(surface_id)}"}
    end
  end

  defp parse_action(%{"action" => %{"name" => name} = inner}) when is_binary(name),
    do: {:ok, name, inner["context"] || %{}}

  defp parse_action(%{"name" => name} = inner) when is_binary(name),
    do: {:ok, name, inner["context"] || %{}}

  defp parse_action(_action), do: {:error, -32_602, "action must be an A2UI action envelope"}

  # Reads run at once; a write asks first, and runs on the second call.
  defp act(entry, ui, _action, name, context, _actor, nil) when name in @writes do
    {resource, action_name} = target(ui, name, context)

    {:request_permission,
     %{
       title: "#{humanize(action_name || name)} · #{entry.label}",
       kind: :execute,
       inputs: Map.take(context, ["recordId", "values"]),
       resource: resource,
       action: action_name
     }}
  end

  defp act(_entry, _ui, _action, name, _context, _actor, :denied) when name in @writes,
    do: {:ok, %{"outcome" => "denied", "a2ui" => []}}

  defp act(_entry, ui, action, _name, _context, actor, _permission) do
    {_ok_or_error, messages} =
      AshA2ui.ActionHandler.handle(ui, action,
        actor: actor,
        tenant: ActorContext.tenant(actor)
      )

    {:ok, %{"outcome" => "applied", "a2ui" => messages}}
  end

  # The resource and Ash action a write runs, for the approval record: a row
  # action by its declared name, a form by its create/update action.
  defp target(ui, name, context) do
    view = AshA2ui.ResolvedView.resolve(ui, [])

    action_name =
      case name do
        "submit_form" ->
          if context["recordId"], do: view.update_action, else: view.create_action

        _row_action ->
          Enum.find(view.row_actions, &(Atom.to_string(&1) == context["action"]))
      end

    {view.resource, action_name}
  end

  defp humanize(name), do: name |> to_string() |> String.replace("_", " ") |> String.capitalize()

  # The session's actor; a session-less call (a capabilities index at
  # `initialize`) runs as the deployment's operator, exactly as a new session
  # would (`AshEnterprise.Acp.SessionStore.create/1`).
  defp actor(%{actor: nil}), do: Acp.system_actor() |> with_context()
  defp actor(%{actor: actor}), do: with_context(actor)

  # `for_actor/1` returns an attached context as-is and builds one otherwise.
  defp with_context(%{__struct__: _} = user),
    do: ActorContext.attach(user, ActorContext.for_actor(user))

  defp with_context(actor), do: actor
end
