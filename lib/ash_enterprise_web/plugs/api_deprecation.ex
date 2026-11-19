defmodule AshEnterpriseWeb.Plugs.ApiDeprecation do
  @moduledoc """
  Tells a caller that the route it called is going away.

  `priv/api/deprecations.json` announces elements of the API contract. For an entry
  naming a route (`route:get /api/json/teams/{}`) this plug answers a matching request with

    * `Deprecation: @<epoch>` -- when it was announced (RFC 9745)
    * `Sunset: <IMF-fixdate>` -- when it ends (RFC 8594)
    * `Link: <notice>; rel="deprecation"` -- where the caller reads what to do instead

  An entry for `endpoint:graphql` does the same for every request to the GraphQL
  endpoint. Entries for single properties, GraphQL fields and arguments have no route
  to hang a header on; they are announced in the notice their `link` names.

  The file is read at compile time (`@external_resource`), so a request never reads it.
  Tests swap the entries with `config :ash_enterprise, #{inspect(__MODULE__)}, entries: ...`.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshEnterpriseWeb.ApiContract
  alias AshEnterpriseWeb.ApiContract.Deprecations

  @file_path Path.expand("../../../" <> ApiContract.deprecations_file(), __DIR__)
  @external_resource @file_path

  @entries elem(Deprecations.read!(@file_path), 0)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    entries = configured_entries()
    segments = conn.path_info
    method = String.downcase(conn.method)

    case Enum.find(entries, &matches?(&1.element, method, segments)) do
      nil ->
        conn

      entry ->
        {deprecation, sunset} = Deprecations.header_values(entry)

        conn
        |> put_resp_header("deprecation", deprecation)
        |> put_resp_header("sunset", sunset)
        |> put_resp_header("link", ~s(<#{entry.link}>; rel="deprecation"))
    end
  end

  defp configured_entries do
    :ash_enterprise |> Application.get_env(__MODULE__, []) |> Keyword.get(:entries, @entries)
  end

  defp matches?("endpoint:graphql", _method, segments),
    do: List.starts_with?(segments, split(ApiContract.graphql_path()))

  defp matches?("route:" <> route, method, segments) do
    [route_method, path] = String.split(route, " ", parts: 2)
    pattern = split(path)

    route_method == method and length(pattern) == length(segments) and
      Enum.zip(pattern, segments) |> Enum.all?(fn {p, s} -> placeholder?(p) or p == s end)
  end

  defp matches?(_other, _method, _segments), do: false

  defp placeholder?("{" <> _), do: true
  defp placeholder?(_), do: false

  defp split(path), do: String.split(path, "/", trim: true)
end
