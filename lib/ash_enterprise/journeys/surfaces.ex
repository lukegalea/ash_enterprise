defmodule AshEnterprise.Journeys.Surfaces do
  @moduledoc """
  The surfaces a journey's steps name (`open`, `lands_on`, `ui/1`), for
  `AshJourneys.SurfaceRegistry`.

  Every surface of `AshEnterprise.Surfaces` that has a path, by its registry key,
  plus the two pages a person passes through that are not registry surfaces: the
  launcher (`/app`) and the sign-in page. Neither is an A2UI surface, so a journey
  can open or land on them but name no table or row action there.
  """

  @behaviour AshJourneys.SurfaceRegistry

  @pages %{launcher: "/app", sign_in: "/sign-in"}

  @impl true
  def surface(id) when is_map_key(@pages, id), do: %{ui: nil}

  def surface(id) when is_atom(id) do
    case AshEnterprise.Surfaces.fetch(id) do
      %{path: path, ui: ui} when is_binary(path) -> %{ui: ui}
      _no_page -> nil
    end
  end

  @doc "The web path that opens surface `id`."
  @spec path(atom()) :: String.t()
  def path(id) when is_map_key(@pages, id), do: Map.fetch!(@pages, id)
  def path(id), do: AshEnterprise.Surfaces.fetch!(id).path
end
