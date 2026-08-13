defmodule AshEnterpriseWeb.ApiSurfacesTest do
  @moduledoc """
  Tests the properties of the public API surfaces that are easy to regress and
  expensive to get wrong.

  These are not "does the endpoint respond" smoke tests. Each one asserts a
  security property that would fail *silently* if the wiring drifted.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  describe "JSON:API" do
    test "an unauthenticated read returns an empty collection, not a 403", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/json/teams")

      # This is the behaviour that matters. Ash FILTERS read actions rather than
      # forbidding them, so a caller sees the subset they may see -- here, none.
      #
      # A 403 would be worse in two ways: it confirms the collection exists, and
      # it pushes clients toward treating authorization failures as exceptional
      # rather than as ordinary empty results.
      assert %{"data" => []} = json_response(conn, 200)
    end

    test "publishes an OpenAPI document covering exactly the exposed resources", %{conn: conn} do
      # NOTE: ash_json_api serves the OpenAPI document with a 200 and a valid
      # JSON body but sets NO content-type header, so `json_response/2` refuses
      # it. Decode the body directly rather than working around it by loosening
      # the assertion. Worth knowing if a client's tooling rejects the document.
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/json/open_api")

      assert response.status == 200

      paths =
        response.resp_body
        |> Jason.decode!()
        |> Map.fetch!("paths")
        |> Map.keys()
        |> Enum.sort()

      assert "/api/json/teams" in paths
      assert "/api/json/business_units" in paths

      # Exposure is opt-in per resource. Nothing from the Security or Audit
      # domains may appear here: a filterable public API over the authorization
      # tables is a map of the security model, and over the audit log it
      # discloses records the caller cannot otherwise read.
      refute Enum.any?(paths, &String.contains?(&1, "role"))
      refute Enum.any?(paths, &String.contains?(&1, "privilege"))
      refute Enum.any?(paths, &String.contains?(&1, "access_grant"))
      refute Enum.any?(paths, &String.contains?(&1, "audit"))
    end
  end

  describe "GraphQL" do
    test "exposes the declared queries and nothing from Security or Audit", %{conn: conn} do
      fields =
        conn
        |> post("/gql", %{query: "{ __schema { queryType { fields { name } } } }"})
        |> json_response(200)
        |> get_in(["data", "__schema", "queryType", "fields"])
        |> Enum.map(& &1["name"])

      assert "listTeams" in fields
      assert "listBusinessUnits" in fields

      refute Enum.any?(fields, &String.contains?(String.downcase(&1), "role"))
      refute Enum.any?(fields, &String.contains?(String.downcase(&1), "audit"))
    end
  end

  describe "MCP" do
    test "rejects an actorless request outright rather than returning empty results",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", %{})

      # Policies already fail closed, so an anonymous caller would read nothing.
      # We still reject at the door: an MCP endpoint that accepts anonymous
      # connections and quietly returns nothing looks like a working integration
      # with no data, and the natural next step for whoever is debugging that is
      # to relax authorization until data appears.
      assert conn.status == 401
      assert %{"error" => "unauthenticated"} = Jason.decode!(conn.resp_body)
    end
  end
end
