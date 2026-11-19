defmodule AshEnterpriseWeb.Plugs.ApiDeprecationTest do
  use AshEnterpriseWeb.ConnCase, async: false

  alias AshEnterpriseWeb.Plugs.ApiDeprecation

  defp announce(entries) do
    Application.put_env(:ash_enterprise, ApiDeprecation, entries: entries)
    on_exit(fn -> Application.delete_env(:ash_enterprise, ApiDeprecation) end)
  end

  defp entry(element) do
    %{
      element: element,
      announced: ~D[2026-01-01],
      sunset: ~D[2027-03-01],
      link: "https://example.test/notice"
    }
  end

  defp api_get(conn, path) do
    conn |> put_req_header("accept", "application/vnd.api+json") |> get(path)
  end

  test "a deprecated route answers with Deprecation, Sunset and Link headers", %{conn: conn} do
    announce([entry("route:get /api/json/teams")])

    conn = api_get(conn, "/api/json/teams")

    assert get_resp_header(conn, "deprecation") == ["@1767225600"]
    assert get_resp_header(conn, "sunset") == ["Mon, 01 Mar 2027 00:00:00 GMT"]
    assert get_resp_header(conn, "link") == [~s(<https://example.test/notice>; rel="deprecation")]
  end

  test "an undeprecated route carries none", %{conn: conn} do
    announce([entry("route:get /api/json/teams")])

    conn = api_get(conn, "/api/json/positions")

    assert get_resp_header(conn, "deprecation") == []
    assert get_resp_header(conn, "sunset") == []
    assert get_resp_header(conn, "link") == []
  end

  test "the method counts: a deprecated GET does not mark a POST", %{conn: conn} do
    announce([entry("route:get /api/json/teams")])

    conn =
      conn
      |> put_req_header("content-type", "application/vnd.api+json")
      |> api_get("/api/json/teams")

    assert get_resp_header(conn, "deprecation") != []

    conn =
      build_conn()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/json/teams", "{}")

    assert get_resp_header(conn, "deprecation") == []
  end

  test "a path parameter matches any one segment", %{conn: conn} do
    announce([entry("route:get /api/json/teams/{}")])

    marked = api_get(conn, "/api/json/teams/#{Ecto.UUID.generate()}")
    assert get_resp_header(marked, "deprecation") != []

    unmarked = api_get(build_conn(), "/api/json/teams")
    assert get_resp_header(unmarked, "deprecation") == []
  end

  test "a whole-endpoint sunset marks every GraphQL request", %{conn: conn} do
    announce([entry("endpoint:graphql")])

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/gql", Jason.encode!(%{query: "{ __typename }"}))

    assert get_resp_header(conn, "sunset") == ["Mon, 01 Mar 2027 00:00:00 GMT"]
  end

  test "with nothing announced no request is marked", %{conn: conn} do
    announce([])
    assert api_get(conn, "/api/json/teams") |> get_resp_header("deprecation") == []
  end
end
