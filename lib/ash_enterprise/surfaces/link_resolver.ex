defmodule AshEnterprise.Surfaces.LinkResolver do
  @moduledoc """
  `AshA2ui.LinkResolver` for this application: which registry surface a
  reference link opens, per actor (`config :ash_a2ui, :link_resolver`).

    * `{:resource, module}` — a relationship link (`link :sender`) opens the
      surface that shows one record of `module` in detail
      (`AshEnterprise.Surfaces.record_surface/1`).
    * `{:surface, key}` — an explicit link (`link {:users, :decided_by_id}`)
      opens that surface, if it has a detail.
    * `{:surface, "record"}` — the polymorphic target: the id is a typed
      reference (`<surface>:<id>`) resolved when the link is opened
      (`AshEnterprise.Surfaces.Records`).

  A surface whose door is closed for the actor is vetoed (`nil`): the cell
  shows its value with no link, rather than a link that bounces. Links are UX,
  not authorization — opening one re-authorizes the record as the actor.
  """

  @behaviour AshA2ui.LinkResolver

  alias AshEnterprise.Surfaces

  @impl true
  def surface_for({:resource, resource}, %{actor: actor}),
    do: resource |> Surfaces.record_surface() |> openable(actor)

  def surface_for({:surface, "record"}, %{actor: actor}) when not is_nil(actor), do: "record"

  def surface_for({:surface, key}, %{actor: actor}),
    do: key |> Surfaces.fetch() |> openable(actor)

  def surface_for(_target, _context), do: nil

  defp openable(%{context: context} = surface, actor) when not is_nil(context) do
    if Surfaces.open?(surface, actor), do: Atom.to_string(surface.key)
  end

  defp openable(_no_detail, _actor), do: nil
end
