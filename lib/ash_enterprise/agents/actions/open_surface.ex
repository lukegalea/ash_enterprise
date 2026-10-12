defmodule AshEnterprise.Agents.Actions.OpenSurface do
  @moduledoc """
  `Console.open`: the transcript line for opening a registry surface over ACP
  (`open <surface>`, or the surface's own command). The surface itself
  arrives in the A2UI pane (`AshEnterprise.Acp.Surfaces`); this says which
  one, and — for a hand-written page with no A2UI surface — where it lives on
  the web.

  The surface's door is checked here as well as in the grammar
  (`AshEnterprise.Acp.Commands`), so the action cannot be used to step past
  one: a closed door is `Forbidden`, exactly as on the web.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.DoorClosed

  @impl true
  def run(input, _opts, context) do
    case Surfaces.fetch(input.arguments.surface) do
      nil ->
        {:error, "no surface named #{inspect(input.arguments.surface)} — say `help` for yours"}

      surface ->
        if Surfaces.open?(surface, context.actor) do
          {:ok, text(surface)}
        else
          {:error, DoorClosed.exception(label: surface.label, door: surface.door)}
        end
    end
  end

  @doc "The transcript line for `surface`."
  def text(%{ui: nil} = surface),
    do: "#{surface.label} — #{surface.blurb}\nOn the web: #{surface.path}"

  def text(surface), do: "#{surface.label} — #{surface.blurb}"
end
