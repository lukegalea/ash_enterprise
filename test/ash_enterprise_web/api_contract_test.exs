defmodule AshEnterpriseWeb.ApiContractTest do
  @moduledoc """
  The pinned API contract (ADR 0019, amended): what is pinned, what counts as breaking,
  and when a breaking change may be pinned.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  alias AshEnterpriseWeb.ApiContract
  alias AshEnterpriseWeb.ApiContract.{Deprecations, Diff}

  @today ~D[2026-11-17]

  defp pinned_doc, do: "priv/api/openapi.json" |> File.read!() |> Jason.decode!()
  defp pinned_sdl, do: File.read!("priv/api/schema.graphql")

  defp classify(change_doc, change_sdl \\ & &1) do
    Diff.classify(
      {pinned_doc(), pinned_sdl()},
      {change_doc.(pinned_doc()), change_sdl.(pinned_sdl())}
    )
  end

  defp entry(element, announced, sunset) do
    %{element: element, announced: announced, sunset: sunset, link: "https://example.test/notice"}
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "api-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "priv/api"))

    for f <- File.ls!("priv/api"),
        do: File.cp!(Path.join("priv/api", f), Path.join([root, "priv/api", f]))

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # Pin a contract that has one route the build does not: re-pinning would remove it.
  defp root_pinning_an_extra_route(deprecations \\ []) do
    root = tmp_root()
    path = Path.join(root, "priv/api/openapi.json")

    doc = path |> File.read!() |> Jason.decode!()
    extra = %{"get" => %{"responses" => %{"200" => %{"description" => "ok"}}}}
    doc = put_in(doc, ["paths", "/retired"], extra)

    openapi = ApiContract.canonical_json(doc)
    File.write!(path, openapi)

    File.write!(
      Path.join(root, "priv/api/contract.lock.json"),
      ApiContract.lock(openapi, pinned_sdl())
    )

    File.write!(
      Path.join(root, "priv/api/deprecations.json"),
      Deprecations.encode(deprecations, [])
    )

    root
  end

  describe "the pin" do
    test "the served /api/json/open_api equals the pinned openapi.json", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/json/open_api")
        |> response(200)
        |> Jason.decode!()

      assert body |> Map.delete("servers") |> ApiContract.canonical_json() ==
               File.read!("priv/api/openapi.json")
    end

    test "the pinned GraphQL schema is the one the endpoint is built from" do
      assert ApiContract.graphql_sdl() == pinned_sdl()
      refute pinned_sdl() =~ "say_hello"
    end

    test "the pinned files match contract.lock's sha-256" do
      lock = "priv/api/contract.lock.json" |> File.read!() |> Jason.decode!()

      assert lock == %{
               "priv/api/openapi.json" =>
                 AshOperations.Spec.sha256(File.read!("priv/api/openapi.json")),
               "priv/api/schema.graphql" => AshOperations.Spec.sha256(pinned_sdl())
             }
    end

    test "a pinned file edited by hand fails the check" do
      root = tmp_root()
      File.write!(Path.join(root, "priv/api/schema.graphql"), pinned_sdl() <> "\n# hand edit\n")

      assert {:error, problems} = ApiContract.check(root, @today)
      assert Enum.any?(problems, &(&1 =~ "edited by hand"))
    end

    test "a missing pin fails the check and names the fix" do
      root = tmp_root()
      File.rm!(Path.join(root, "priv/api/openapi.json"))

      assert {:error, [message | _]} = ApiContract.check(root, @today)
      assert message =~ "openapi.json is missing"
    end

    test "the committed pin is current and the committed deprecations are sound" do
      assert {:ok, []} = ApiContract.check(".", @today)
    end

    test "rendering is deterministic: the same contract is the same bytes" do
      assert ApiContract.openapi() == ApiContract.openapi()
      refute ApiContract.openapi() =~ ~s("servers")
    end
  end

  describe "what is breaking" do
    test "removing a route without a deprecation entry is breaking" do
      %{breaking: breaking} =
        classify(fn doc -> update_in(doc, ["paths"], &Map.delete(&1, "/api/json/teams/{id}")) end)

      assert %{element: "route:get /api/json/teams/{}", reason: "removed"} in breaking
      # The route's own properties are not reported a second time.
      refute Enum.any?(
               breaking,
               &String.starts_with?(&1.element, "property:get /api/json/teams/{}")
             )

      assert Diff.unannounced(breaking, [], @today) == breaking
    end

    test "removing a route whose sunset has not passed is still breaking" do
      %{breaking: breaking} =
        classify(fn doc -> update_in(doc, ["paths"], &Map.delete(&1, "/api/json/teams/{id}")) end)

      announced = [entry("route:get /api/json/teams/{}", ~D[2026-11-01], ~D[2027-03-01])]
      assert Diff.unannounced(breaking, announced, @today) == breaking

      past = [entry("route:get /api/json/teams/{}", ~D[2026-01-01], ~D[2026-11-17])]
      assert Diff.unannounced(breaking, past, @today) == []
    end

    test "changing an attribute's type is breaking" do
      %{breaking: breaking} =
        classify(fn doc ->
          put_in(
            doc,
            [
              "components",
              "schemas",
              "business_unit",
              "properties",
              "attributes",
              "properties",
              "name"
            ],
            %{"type" => "integer"}
          )
        end)

      assert Enum.any?(
               breaking,
               &(&1.reason == "type changed" and
                   &1.element =~ "property:components.business_unit.attributes.name")
             )
    end

    test "adding an optional attribute is additive" do
      result =
        classify(fn doc ->
          update_in(
            doc,
            ["components", "schemas", "team", "properties"],
            &Map.put(&1, "nickname", %{"type" => "string"})
          )
        end)

      assert result.breaking == []
      assert result.changed?
    end

    test "a property newly required of a request body is breaking" do
      %{breaking: breaking} =
        classify(fn doc ->
          update_in(
            doc,
            [
              "paths",
              "/api/json/teams",
              "post",
              "requestBody",
              "content",
              "application/vnd.api+json",
              "schema",
              "properties",
              "data",
              "properties",
              "attributes"
            ],
            fn attrs -> Map.update(attrs, "required", ["description"], &["description" | &1]) end
          )
        end)

      assert Enum.any?(breaking, &(&1.reason == "newly required" and &1.element =~ "description"))
    end

    test "a new route that requires a body is additive" do
      result =
        classify(fn doc ->
          route = %{
            "post" => %{
              "parameters" => [
                %{
                  "name" => "id",
                  "in" => "query",
                  "required" => true,
                  "schema" => %{"type" => "string"}
                }
              ],
              "requestBody" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{
                      "type" => "object",
                      "required" => ["name"],
                      "properties" => %{"name" => %{"type" => "string"}}
                    }
                  }
                }
              }
            }
          }

          put_in(doc, ["paths", "/api/json/widgets"], route)
        end)

      assert result.breaking == []
      assert result.changed?
    end

    test "a response property newly required is additive" do
      result =
        classify(fn doc ->
          update_in(doc, ["components", "schemas", "business_unit"], fn schema ->
            Map.update(schema, "required", ["attributes"], &["attributes" | &1])
          end)
        end)

      assert result.breaking == []
    end

    test "removing a GraphQL field is breaking" do
      %{breaking: breaking} =
        classify(
          & &1,
          &String.replace(
            &1,
            "\n  \"The first keyset in the results\"\n  startKeyset: String\n",
            "\n",
            global: false
          )
        )

      assert %{element: "graphql:KeysetPageOfPosition.startKeyset", reason: "removed"} in breaking
    end

    test "a GraphQL argument made non-null is breaking" do
      %{breaking: breaking} =
        classify(
          & &1,
          &String.replace(&1, "filter: PositionFilterInput", "filter: PositionFilterInput!",
            global: false
          )
        )

      assert Enum.any?(breaking, &(&1.reason == "type changed" and &1.element =~ "(filter)"))
    end

    test "a GraphQL type added is additive" do
      result = classify(& &1, &(&1 <> "\ntype Added {\n  id: ID\n}\n"))
      assert result.breaking == []
      assert result.changed?
    end

    test "an identical contract changed nothing" do
      assert %{breaking: [], changed?: false} = classify(& &1)
    end
  end

  describe "re-pinning" do
    test "a breaking change no announcement permits is refused, and nothing is written" do
      root = root_pinning_an_extra_route()
      before = File.read!(Path.join(root, "priv/api/openapi.json"))

      assert {:error, [%{element: "route:get /retired", reason: "removed"}]} =
               ApiContract.write(root, @today)

      assert File.read!(Path.join(root, "priv/api/openapi.json")) == before
    end

    test "check reports the same change as BREAKING" do
      root = root_pinning_an_extra_route()

      assert {:error, problems} = ApiContract.check(root, @today)
      assert Enum.any?(problems, &(&1 =~ "BREAKING route:get /retired"))
    end

    test "an announced removal past its sunset is pinned, and its announcement is retired" do
      root =
        root_pinning_an_extra_route([entry("route:get /retired", ~D[2026-01-01], ~D[2026-11-01])])

      assert {:ok, _} = ApiContract.write(root, @today)
      assert {:ok, []} = ApiContract.check(root, @today)

      {live, retired} = Deprecations.read!(Path.join(root, "priv/api/deprecations.json"))
      assert live == []
      assert [%{"element" => "route:get /retired"}] = retired
    end

    test "an announced removal before its sunset is refused" do
      root =
        root_pinning_an_extra_route([entry("route:get /retired", ~D[2026-11-01], ~D[2027-03-01])])

      assert {:error, [%{element: "route:get /retired"}]} = ApiContract.write(root, @today)
    end
  end

  describe "deprecations.json" do
    test "an entry naming no pinned route fails the check" do
      root = tmp_root()
      entries = [entry("route:get /nowhere", ~D[2026-01-01], ~D[2027-01-01])]
      File.write!(Path.join(root, "priv/api/deprecations.json"), Deprecations.encode(entries, []))

      assert {:error, problems} = ApiContract.check(root, @today)

      assert Enum.any?(
               problems,
               &(&1 =~ "route:get /nowhere: names nothing in the pinned contract")
             )
    end

    test "a sunset closer than the minimum notice fails the check" do
      root = tmp_root()
      entries = [entry("route:get /api/json/teams", ~D[2026-11-01], ~D[2026-12-01])]
      File.write!(Path.join(root, "priv/api/deprecations.json"), Deprecations.encode(entries, []))

      assert {:error, problems} = ApiContract.check(root, @today)
      assert Enum.any?(problems, &(&1 =~ "the minimum is #{Deprecations.minimum_notice_days()}"))
    end

    test "an announcement of a pinned route and of the GraphQL endpoint is sound" do
      root = tmp_root()

      entries = [
        entry("route:get /api/json/teams", ~D[2026-11-01], ~D[2027-03-01]),
        entry("endpoint:graphql", ~D[2026-11-01], ~D[2027-03-01])
      ]

      File.write!(Path.join(root, "priv/api/deprecations.json"), Deprecations.encode(entries, []))
      assert {:ok, []} = ApiContract.check(root, @today)
    end

    test "the headers carry RFC 9745 and RFC 8594 values" do
      assert {"@1767225600", "Mon, 01 Mar 2027 00:00:00 GMT"} ==
               Deprecations.header_values(entry("x", ~D[2026-01-01], ~D[2027-03-01]))
    end
  end

  describe "the gate: the pin a change commits, against the pin it started from" do
    # A git repository whose one commit, made on `date`, pins a contract with a route the
    # build does not have and carries `deprecations`. Returns `{root, base}`.
    defp base_pinning_an_extra_route(deprecations, date) do
      root = root_pinning_an_extra_route(deprecations)
      git!(root, ["init", "--quiet"], date)
      git!(root, ["add", "priv/api"], date)
      git!(root, ["commit", "--quiet", "-m", "pin"], date)
      {root, root |> git!(["rev-parse", "HEAD"], date) |> String.trim()}
    end

    # The change: the route is gone from the pin, written by hand with a lock that agrees,
    # as `--write` would write it, and `deprecations` as the change leaves them.
    defp remove_the_route_by_hand(root, deprecations, retired \\ []) do
      for f <- ["openapi.json", "schema.graphql", "contract.lock.json"],
          do: File.cp!(Path.join("priv/api", f), Path.join([root, "priv/api", f]))

      File.write!(
        Path.join(root, "priv/api/deprecations.json"),
        Deprecations.encode(deprecations, retired)
      )
    end

    defp git!(root, args, date) do
      env = [
        {"GIT_AUTHOR_DATE", date},
        {"GIT_COMMITTER_DATE", date},
        {"GIT_AUTHOR_NAME", "Contract Test"},
        {"GIT_AUTHOR_EMAIL", "contract@example.test"},
        {"GIT_COMMITTER_NAME", "Contract Test"},
        {"GIT_COMMITTER_EMAIL", "contract@example.test"}
      ]

      {output, 0} =
        System.cmd("git", ["-c", "commit.gpgsign=false" | args],
          cd: root,
          env: env,
          stderr_to_stdout: true
        )

      output
    end

    test "a removal re-pinned by hand passes --check alone, and the gate refuses it" do
      {root, base} = base_pinning_an_extra_route([], "2026-01-01T12:00:00Z")
      remove_the_route_by_hand(root, [])

      # The pin agrees with the build and with its lock: drift alone cannot see it.
      assert {:ok, []} = ApiContract.check(root, @today)

      assert {:error, [problem]} = ApiContract.check_against(base, root, @today)
      assert problem =~ "BREAKING route:get /retired: removed"
    end

    test "an announcement the change itself adds permits nothing, whatever dates it claims" do
      {root, base} = base_pinning_an_extra_route([], "2026-01-01T12:00:00Z")
      back_dated = entry("route:get /retired", ~D[2026-01-01], ~D[2026-04-01])
      remove_the_route_by_hand(root, [back_dated])

      assert {:error, [problem]} = ApiContract.check_against(base, root, @today)
      assert problem =~ "BREAKING route:get /retired"
    end

    test "a back-dated announcement counts from the day it reached the base, not the date it claims" do
      back_dated = entry("route:get /retired", ~D[2026-01-01], ~D[2026-04-01])
      {root, base} = base_pinning_an_extra_route([back_dated], "2026-11-01T12:00:00Z")
      remove_the_route_by_hand(root, [], [])

      assert {:error, [problem]} = ApiContract.check_against(base, root, @today)
      assert problem =~ "BREAKING route:get /retired"
    end

    test "an announcement on the base for the full notice, past its sunset, permits the removal" do
      announced = entry("route:get /retired", ~D[2026-01-01], ~D[2026-04-15])
      {root, base} = base_pinning_an_extra_route([announced], "2026-01-01T12:00:00Z")

      remove_the_route_by_hand(root, [], [
        %{
          "element" => "route:get /retired",
          "announced" => "2026-01-01",
          "sunset" => "2026-04-15",
          "link" => announced.link
        }
      ])

      assert {:ok, [_note]} = ApiContract.check_against(base, root, @today)
    end

    test "the same announcement before its sunset still refuses the removal" do
      announced = entry("route:get /retired", ~D[2026-11-01], ~D[2027-03-01])
      {root, base} = base_pinning_an_extra_route([announced], "2026-11-01T12:00:00Z")
      remove_the_route_by_hand(root, [])

      assert {:error, [_problem]} = ApiContract.check_against(base, root, @today)
    end

    test "an unchanged pin, and a base with no pinned contract, pass" do
      {root, base} = base_pinning_an_extra_route([], "2026-01-01T12:00:00Z")
      assert {:ok, [_note]} = ApiContract.check_against(base, root, @today)

      empty = Path.join(System.tmp_dir!(), "api-contract-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)
      File.write!(Path.join(empty, "README"), "nothing pinned")
      git!(empty, ["init", "--quiet"], "2026-01-01T12:00:00Z")
      git!(empty, ["add", "README"], "2026-01-01T12:00:00Z")
      git!(empty, ["commit", "--quiet", "-m", "start"], "2026-01-01T12:00:00Z")
      head = empty |> git!(["rev-parse", "HEAD"], "2026-01-01T12:00:00Z") |> String.trim()

      assert {:ok, [note]} = ApiContract.check_against(head, empty, @today)
      assert note =~ "no contract was pinned"
    end
  end
end
