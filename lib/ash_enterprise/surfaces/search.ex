defmodule AshEnterprise.Surfaces.Search do
  @moduledoc """
  Finding a record by what a person knows about it: a business reference (a
  credential's licence number) or a run id (a process run, a lineage run).

  Each registry entry declares the attributes that identify one of its
  records (`searchable`). `find/2` looks the typed value up in every surface
  the actor may open (`AshEnterprise.Surfaces.openable/1`) that declares
  some, as the actor: an authorized read of the surface's resource on its
  primary read action, so a record they may not read is not found. A value
  is only compared with an attribute it casts to, so a licence number never
  reaches a UUID column and a UUID is never compared with a name.

  A hit is a deep link (`/app/r/<surface>/<id>`), which re-authorizes when it
  is opened (`AshEnterprise.Surfaces.Records`), so a list read a moment ago is
  never trusted on its own.

  A surface whose read fails is reported in `failed`, never folded into "no
  match": a search that could not look somewhere says so.
  """

  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Surfaces.Surface

  @limit 10

  @typedoc "One record found: the surface it opens on, its id, the attribute that matched."
  @type hit :: %{surface: Surface.t(), id: String.t(), field: atom(), path: String.t()}

  @type result :: %{hits: [hit()], failed: [Surface.t()]}

  @doc """
  The records `term` identifies, for `actor`, across `surfaces` (by default
  every surface the actor may open that declares `searchable`). A blank term
  reads nothing.
  """
  @spec find(String.t() | nil, term(), [Surface.t()] | nil) :: result()
  def find(term, actor, surfaces \\ nil)

  def find(term, actor, surfaces) when is_binary(term) do
    case String.trim(term) do
      "" ->
        %{hits: [], failed: []}

      term ->
        (surfaces || searchable(actor))
        |> Enum.map(&{&1, look_up(&1, term, actor)})
        |> Enum.reduce(%{hits: [], failed: []}, fn
          {_surface, {:ok, hits}}, acc -> %{acc | hits: acc.hits ++ hits}
          {surface, :error}, acc -> %{acc | failed: acc.failed ++ [surface]}
        end)
    end
  end

  def find(_term, _actor, _surfaces), do: %{hits: [], failed: []}

  @doc "The surfaces `actor` may open that declare something to search."
  @spec searchable(term()) :: [Surface.t()]
  def searchable(actor), do: Enum.filter(Surfaces.openable(actor), &(&1.searchable != []))

  defp look_up(%Surface{searchable: fields} = surface, term, actor) do
    case matchable(surface, fields, term) do
      [] -> {:ok, []}
      matches -> read(surface, matches, actor)
    end
  rescue
    _error -> :error
  end

  # Each attribute the term casts to, with the cast value. An attribute the
  # resource does not have is an error in the registry, not a miss.
  defp matchable(%Surface{resource: resource}, fields, term) do
    for field <- fields,
        attribute = Ash.Resource.Info.attribute(resource, field) || raise("no #{field}"),
        {:ok, value} when not is_nil(value) <-
          [Ash.Type.cast_input(attribute.type, term, attribute.constraints)],
        do: {field, value}
  end

  defp read(%Surface{resource: resource} = surface, matches, actor) do
    filter = [or: Enum.map(matches, fn {field, value} -> [{field, value}] end)]

    resource
    |> Ash.Query.do_filter(filter)
    |> Ash.Query.limit(@limit)
    |> Ash.read(actor: actor, tenant: ActorContext.tenant(actor))
    |> case do
      {:ok, records} -> {:ok, Enum.map(records, &hit(surface, &1, matches))}
      {:error, _error} -> :error
    end
  end

  defp hit(surface, record, matches) do
    id = to_string(record.id)

    %{
      surface: surface,
      id: id,
      field:
        Enum.find_value(matches, fn {field, value} -> Map.get(record, field) == value && field end) ||
          matches |> hd() |> elem(0),
      path: "/app/r/#{surface.key}/#{id}"
    }
  end
end
