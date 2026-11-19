defmodule AshEnterpriseWeb.ApiContract.Diff do
  @moduledoc """
  Classifies what changed between two API contracts (ADR 0019, amended).

  A contract is an OpenAPI document (decoded JSON) and a GraphQL schema (SDL text).
  Each is flattened into elements keyed by a stable id:

    * `route:<method> <path>` -- an operation; path parameters are compared by position,
      not name
    * `param:<method> <path>:<in>:<name>` -- a query or header parameter
    * `property:<where>:<dotted path>` -- a schema property, in a response, a request
      body or a component
    * `graphql:Type`, `graphql:Type.field`, `graphql:Type.field(arg)` and
      `graphql:Enum.VALUE`

  A change is **breaking** when a caller that worked against the old contract can stop
  working: an element removed, a property or argument whose type changed, a property
  or parameter newly required of a request, an argument or input field newly non-null.
  A new route or type brings its own required inputs, which no existing caller sends, so
  they are not breaking; a required input added to an existing route is. Anything else
  (an element added, a description changed) is **additive** and needs
  only a re-pin. Elements that vanish because their route or type vanished are not
  listed again: the removal of the parent is the one finding.
  """

  alias AshEnterpriseWeb.ApiContract.Deprecations

  @methods ~w(get post put patch delete head options)
  @shape_keys ~w(type format $ref items anyOf oneOf allOf nullable)

  @type element :: %{
          required(:id) => String.t(),
          required(:shape) => term(),
          optional(:required?) => boolean(),
          optional(:request?) => boolean(),
          optional(:parent) => String.t() | nil
        }

  @type finding :: %{element: String.t(), reason: String.t()}

  @doc "Every element id of a contract: what a deprecation entry may name."
  @spec element_ids(map(), String.t()) :: MapSet.t(String.t())
  def element_ids(openapi, sdl) do
    (openapi_elements(openapi) ++ graphql_elements(sdl))
    |> MapSet.new(& &1.id)
  end

  @doc "Compare a pinned contract with a generated one: `%{breaking: [...], additive?: boolean}`."
  @spec classify({map(), String.t()}, {map(), String.t()}) :: %{
          breaking: [finding()],
          changed?: boolean()
        }
  def classify({old_doc, old_sdl}, {new_doc, new_sdl}) do
    old = openapi_elements(old_doc) ++ graphql_elements(old_sdl)
    new = openapi_elements(new_doc) ++ graphql_elements(new_sdl)
    old_by_id = Map.new(old, &{&1.id, &1})
    new_by_id = Map.new(new, &{&1.id, &1})

    removed_ids =
      old_by_id |> Map.keys() |> Enum.reject(&Map.has_key?(new_by_id, &1)) |> MapSet.new()

    removed =
      for id <- removed_ids,
          el = old_by_id[id],
          not MapSet.member?(removed_ids, el[:parent]),
          do: %{element: id, reason: "removed"}

    changed =
      for {id, new_el} <- new_by_id,
          old_el = old_by_id[id],
          reason = change_reason(old_el, new_el),
          do: %{element: id, reason: reason}

    added =
      for {id, new_el} <- new_by_id,
          not Map.has_key?(old_by_id, id),
          new_el[:required?] == true,
          new_el[:request?] != false,
          Map.has_key?(old_by_id, new_el[:parent]),
          reason = added_reason(new_el),
          do: %{element: id, reason: reason}

    breaking = Enum.sort_by(removed ++ changed ++ added, & &1.element)

    %{
      breaking: breaking,
      changed?: old_doc != new_doc or old_sdl != new_sdl
    }
  end

  defp change_reason(old, new) do
    cond do
      old.shape != new.shape ->
        "type changed"

      new[:required?] == true and old[:required?] != true and new[:request?] == true ->
        "newly required"

      true ->
        nil
    end
  end

  defp added_reason(%{request?: true}), do: "added as required"
  defp added_reason(%{request?: nil, id: "graphql:" <> _}), do: "added as non-null"
  defp added_reason(_), do: nil

  @doc "The breaking findings no announcement permits yet: the ones `--write` must refuse."
  @spec unannounced([finding()], [Deprecations.entry()], Date.t()) :: [finding()]
  def unannounced(findings, entries, today) do
    Enum.reject(findings, &Deprecations.permits_removal?(entries, &1.element, today))
  end

  # --- OpenAPI -------------------------------------------------------------------------

  defp openapi_elements(doc) do
    request_schemas = request_schema_names(doc)

    routes =
      for {path, item} <- doc["paths"] || %{},
          is_map(item),
          {method, op} <- item,
          method in @methods,
          is_map(op),
          reduce: [] do
        acc -> acc ++ operation_elements(method, path, op)
      end

    components =
      for {name, schema} <- get_in(doc, ["components", "schemas"]) || %{},
          el <-
            properties(schema, ["components", name],
              request?: name in request_schemas,
              parent: nil
            ),
          do: el

    routes ++ components
  end

  defp operation_elements(method, path, op) do
    route = "route:#{method} #{shape(path)}"

    params =
      for %{"name" => name, "in" => where} = p <- op["parameters"] || [] do
        %{
          id: "param:#{method} #{shape(path)}:#{where}:#{name}",
          shape: Map.take(p["schema"] || %{}, @shape_keys),
          required?: p["required"] == true,
          request?: true,
          parent: route
        }
      end

    body =
      case op["requestBody"] do
        nil ->
          []

        rb ->
          properties(rb, ["#{method} #{shape(path)}", "requestBody"],
            request?: true,
            parent: route
          )
      end

    responses =
      properties(op["responses"] || %{}, ["#{method} #{shape(path)}", "responses"],
        request?: false,
        parent: route
      )

    [%{id: route, shape: nil, parent: nil}] ++ params ++ body ++ responses
  end

  # The component schemas a request body can carry: those it references, transitively.
  defp request_schema_names(doc) do
    schemas = get_in(doc, ["components", "schemas"]) || %{}

    seeds =
      for {_p, item} <- doc["paths"] || %{},
          is_map(item),
          {m, op} <- item,
          m in @methods,
          is_map(op),
          rb = op["requestBody"],
          name <- refs(rb),
          do: name

    expand(MapSet.new(seeds), schemas)
  end

  defp expand(names, schemas) do
    next =
      Enum.reduce(names, names, fn name, acc ->
        schemas |> Map.get(name, %{}) |> refs() |> Enum.reduce(acc, &MapSet.put(&2, &1))
      end)

    if MapSet.equal?(next, names), do: names, else: expand(next, schemas)
  end

  defp refs(node) when is_map(node) do
    Enum.flat_map(node, fn
      {"$ref", "#/components/schemas/" <> name} -> [name]
      {_, v} -> refs(v)
    end)
  end

  defp refs(node) when is_list(node), do: Enum.flat_map(node, &refs/1)
  defp refs(_), do: []

  # Every `properties` map under `node`, as elements named by the path that reaches them.
  defp properties(node, path, opts) when is_map(node) do
    own =
      case node["properties"] do
        props when is_map(props) ->
          required = List.wrap(node["required"])

          for {name, child} <- props do
            %{
              id: "property:" <> Enum.join(path ++ [name], "."),
              shape: Map.take(child, @shape_keys),
              required?: name in required,
              request?: opts[:request?],
              parent: opts[:parent]
            }
          end

        _ ->
          []
      end

    nested =
      for {key, child} <- node,
          key != "properties",
          el <- properties(child, path ++ [key], opts),
          do: el

    below =
      for {name, child} <- node["properties"] || %{},
          is_map(node["properties"]),
          el <- properties(child, path ++ [name], opts),
          do: el

    own ++ nested ++ below
  end

  defp properties(node, path, opts) when is_list(node) do
    node
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, i} -> properties(child, path ++ [Integer.to_string(i)], opts) end)
  end

  defp properties(_, _, _), do: []

  # `/teams/{id}` and `/teams/{team_id}` are the same endpoint.
  defp shape(path), do: String.replace(path, ~r/\{[^}]*\}/, "{}")

  # --- GraphQL -------------------------------------------------------------------------

  defp graphql_elements(sdl) do
    {:ok, %{input: %{definitions: definitions}}} =
      Absinthe.Phase.Parse.run(%Absinthe.Language.Source{body: sdl}, [])

    Enum.flat_map(definitions, &definition_elements/1)
  end

  defp definition_elements(%Absinthe.Language.ObjectTypeDefinition{name: type, fields: fields}),
    do: [type_element(type, "object") | Enum.flat_map(fields, &field_elements(type, &1))]

  defp definition_elements(%Absinthe.Language.InterfaceTypeDefinition{
         name: type,
         fields: fields
       }),
       do: [type_element(type, "interface") | Enum.flat_map(fields, &field_elements(type, &1))]

  defp definition_elements(%Absinthe.Language.InputObjectTypeDefinition{
         name: type,
         fields: fields
       }) do
    inputs =
      for %{name: name, type: t} <- fields do
        %{
          id: "graphql:#{type}.#{name}",
          shape: render_type(t),
          required?: match?(%Absinthe.Language.NonNullType{}, t),
          parent: "graphql:#{type}"
        }
      end

    [type_element(type, "input") | inputs]
  end

  defp definition_elements(%Absinthe.Language.EnumTypeDefinition{name: type, values: values}) do
    [type_element(type, "enum")] ++
      for %{value: value} <- values,
          do: %{id: "graphql:#{type}.#{value}", shape: "value", parent: "graphql:#{type}"}
  end

  defp definition_elements(%Absinthe.Language.UnionTypeDefinition{name: type, types: types}),
    do: [
      %{
        id: "graphql:#{type}",
        shape: {"union", Enum.map(types, &render_type/1) |> Enum.sort()},
        parent: nil
      }
    ]

  defp definition_elements(%Absinthe.Language.ScalarTypeDefinition{name: type}),
    do: [type_element(type, "scalar")]

  defp definition_elements(_other), do: []

  defp type_element(name, kind), do: %{id: "graphql:#{name}", shape: kind, parent: nil}

  defp field_elements(type, %{name: name, type: t, arguments: args}) do
    field_id = "graphql:#{type}.#{name}"

    field = %{id: field_id, shape: render_type(t), parent: "graphql:#{type}"}

    arguments =
      for %{name: arg, type: at} <- args do
        %{
          id: "graphql:#{type}.#{name}(#{arg})",
          shape: render_type(at),
          required?: match?(%Absinthe.Language.NonNullType{}, at),
          parent: field_id
        }
      end

    [field | arguments]
  end

  defp render_type(%Absinthe.Language.NonNullType{type: t}), do: render_type(t) <> "!"
  defp render_type(%Absinthe.Language.ListType{type: t}), do: "[" <> render_type(t) <> "]"
  defp render_type(%Absinthe.Language.NamedType{name: name}), do: name
end
