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

  Only names are read: never a value from the action's context, so no user input
  reaches a span. To add your own events, write a function that handles them and
  falls through to `resolve/3`.
  """

  alias AshEnterprise.Telemetry.Attributes

  @doc "Attributes for an `a2ui:action` event, or an empty map for any other event."
  @spec resolve(String.t(), map(), term()) :: map()
  def resolve("a2ui:action", %{"action" => %{"name" => name} = action}, socket)
      when is_binary(name) do
    %{
      Attributes.ui_action_name() => name,
      Attributes.ui_surface_id() => action["surfaceId"],
      Attributes.ui_action_resource() => surface_ui(socket)
    }
  end

  def resolve(_event, _params, _socket), do: %{}

  defp surface_ui(%{view: view}) when is_atom(view) and not is_nil(view) do
    if function_exported?(view, :__ash_a2ui_config__, 0) do
      case view.__ash_a2ui_config__() do
        %{ui: ui} -> inspect(ui)
        _other -> nil
      end
    end
  end

  defp surface_ui(_socket), do: nil
end
