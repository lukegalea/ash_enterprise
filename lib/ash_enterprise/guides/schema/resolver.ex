defmodule AshEnterprise.Guides.Schema.Resolver do
  @moduledoc """
  A `JSV.Resolver` that serves the A2UI 1.0 schemas from the copies vendored in
  `ash_a2ui` (`priv/a2ui/v1_0`), never the network, with `catalog.json` naming the
  basic catalog: what `AshEnterprise.Guides.Schema` validates a guide against.

  The spec schemas name each other by basename, so a URI resolves by its basename.
  One pattern in `common_types.json` uses the ECMAScript binary properties
  `\\p{XID_Start}` and `\\p{XID_Continue}`, which PCRE does not know; they are
  rewritten to their general-category definitions from UAX #31 as each file loads.
  """

  # GAP: a runtime validator for agent-to-renderer messages (lukegalea/ash_a2ui#150).
  # ash_a2ui's own copy of this resolver is test-only.

  @behaviour JSV.Resolver

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Audit.Export).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @base "https://a2ui.org/specification/v1_0/"

  @doc "The URI prefix every vendored A2UI 1.0 schema lives under."
  @spec base() :: String.t()
  def base, do: @base

  @doc "The vendored files this resolver serves, for `@external_resource`."
  @spec files() :: [Path.t()]
  def files do
    dir = dir()

    [
      Path.join(dir, "catalogs/basic/v1/catalog.json")
      | Path.wildcard(Path.join(dir, "json/*.json"))
    ]
  end

  # The path is under ash_a2ui's priv dir, by the basename of a schema `$ref` in the
  # vendored files: compile-time input, never a request's.
  @sobelow_skip ["Traversal.FileModule"]
  @impl JSV.Resolver
  def resolve(@base <> _ = uri, _opts) do
    relative =
      case uri |> URI.parse() |> Map.fetch!(:path) |> Path.basename() do
        "catalog.json" -> "catalogs/basic/v1/catalog.json"
        basename -> Path.join("json", basename)
      end

    path = Path.join(dir(), relative)

    if File.exists?(path) do
      schema = path |> File.read!() |> Jason.decode!() |> Map.put("$id", uri)
      {:normal, to_pcre(schema)}
    else
      {:error, {:not_vendored, uri}}
    end
  end

  def resolve(uri, _opts), do: {:error, {:not_an_a2ui_uri, uri}}

  defp dir, do: Application.app_dir(:ash_a2ui, ["priv", "a2ui", "v1_0"])

  defp to_pcre(%{} = schema) do
    Map.new(schema, fn
      {"patternProperties", %{} = props} ->
        {"patternProperties", Map.new(props, fn {k, v} -> {pattern(k), to_pcre(v)} end)}

      {"pattern", value} when is_binary(value) ->
        {"pattern", pattern(value)}

      {key, value} ->
        {key, to_pcre(value)}
    end)
  end

  defp to_pcre(list) when is_list(list), do: Enum.map(list, &to_pcre/1)
  defp to_pcre(other), do: other

  defp pattern(value) do
    value
    |> String.replace("\\p{XID_Start}", "\\p{L}\\p{Nl}")
    |> String.replace("\\p{XID_Continue}", "\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}")
  end
end
