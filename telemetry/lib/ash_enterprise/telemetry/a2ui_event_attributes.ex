defmodule AshEnterprise.Telemetry.A2uiEventAttributes do
  @moduledoc """
  An `:event_attributes` resolver for `ash_a2ui` surfaces.

  A surface pushes one LiveView event, `a2ui:action`, for everything a user does, so
  the event name alone says nothing. This reads the action name and surface from the
  envelope, and the resource or UI module from the LiveView's own surface config:

      AshEnterprise.Telemetry.setup(
        otp_app: :my_app,
        event_attributes: {AshEnterprise.Telemetry.A2uiEventAttributes, :resolve, []}
      )

  For a row action (`invoke`, `bulk_invoke`, `prompt`) the envelope's name is only the
  verb, and the action it runs is in its context, where the client chose it. That
  name is reported only when the surface declares it as a row or bulk action;
  anything else reports the verb, and the client's value appears nowhere. Otherwise a
  client could put any plausible name, such as `drop_tables`, into `ui.action.name`.

  The declared names are read from the UI module's `row_actions` and `bulk_actions`
  (through `AshA2ui.Info`, when `ash_a2ui` is loaded). A host whose surfaces declare
  their actions some other way, such as sections expanded at runtime, supplies them
  with the `:declared` option:

      event_attributes:
        {AshEnterprise.Telemetry.A2uiEventAttributes, :resolve,
         [[declared: {MyAppWeb.Telemetry, :declared_actions, []}]]}

  `:declared` is a list of names (atoms or strings) for every surface, a function of
  `(ui_module, surface_id)`, or an `{module, function, args}` called with
  `ui_module` and `surface_id` before `args`. It returns a list of names.

  Only names are read: never a value from the action's context, so no user input
  reaches a span. To add your own events, write a function that handles them and
  falls through to `resolve/4`.
  """

  alias AshEnterprise.Telemetry.Attributes

  @row_verbs ~w(invoke bulk_invoke prompt)
  @max_action_bytes 64

  # `ash_a2ui` is the host's dependency, not this package's.
  @compile {:no_warn_undefined, AshA2ui.Info}

  @doc "Attributes for an `a2ui:action` event, or an empty map for any other event."
  @spec resolve(String.t(), map(), term(), keyword()) :: map()
  def resolve(event, params, socket, opts \\ [])

  def resolve("a2ui:action", %{"action" => %{"name" => name} = action}, socket, opts)
      when is_binary(name) do
    ui = surface_ui(socket)
    surface_id = action["surfaceId"]

    %{
      Attributes.ui_action_name() => action_name(name, action["context"], ui, surface_id, opts),
      Attributes.ui_surface_id() => surface_id,
      Attributes.ui_action_resource() => ui && inspect(ui)
    }
  end

  def resolve(_event, _params, _socket, _opts), do: %{}

  defp action_name(verb, %{"action" => name}, ui, surface_id, opts)
       when verb in @row_verbs and is_binary(name) and byte_size(name) <= @max_action_bytes do
    declared = opts |> Keyword.get(:declared, &declared_on_ui/2) |> declared(ui, surface_id)

    if Enum.any?(declared, &(name_of(&1) == name)), do: name, else: verb
  end

  defp action_name(verb, _context, _ui, _surface_id, _opts), do: verb

  defp declared(names, _ui, _surface_id) when is_list(names), do: names
  defp declared(fun, ui, surface_id) when is_function(fun, 2), do: list(fun.(ui, surface_id))

  defp declared({module, function, args}, ui, surface_id) when is_list(args),
    do: list(apply(module, function, [ui, surface_id | args]))

  defp declared(_other, _ui, _surface_id), do: []

  defp list(names) when is_list(names), do: names
  defp list(_other), do: []

  defp name_of(name) when is_atom(name), do: Atom.to_string(name)
  defp name_of(name) when is_binary(name), do: name
  defp name_of(_other), do: nil

  @doc """
  The row and bulk actions a UI module declares, read through `AshA2ui.Info`; `[]`
  when there is no UI module or `ash_a2ui` is not loaded. The default for `:declared`.
  """
  @spec declared_on_ui(module() | nil, term()) :: [atom()]
  def declared_on_ui(ui, _surface_id) when is_atom(ui) and not is_nil(ui) do
    if Code.ensure_loaded?(AshA2ui.Info) and Code.ensure_loaded?(ui) do
      ui
      |> AshA2ui.Info.components()
      |> Enum.flat_map(&component_actions/1)
    else
      []
    end
  end

  def declared_on_ui(_ui, _surface_id), do: []

  defp component_actions(component) when is_map(component),
    do:
      List.wrap(Map.get(component, :row_actions)) ++ List.wrap(Map.get(component, :bulk_actions))

  defp component_actions(_component), do: []

  defp surface_ui(%{view: view}) when is_atom(view) and not is_nil(view) do
    if function_exported?(view, :__ash_a2ui_config__, 0) do
      case view.__ash_a2ui_config__() do
        %{ui: ui} when is_atom(ui) and not is_nil(ui) -> ui
        _other -> nil
      end
    end
  end

  defp surface_ui(_socket), do: nil
end
