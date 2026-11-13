defmodule AshEnterpriseWeb.HealthTest do
  @moduledoc """
  `GET /health` (q47): what a load balancer and an uptime prober read, and the SLI of the
  default availability objective.

  The refusals come first: it reads no session and sets no cookie, it answers only the paths
  and methods it owns, a failing check answers 503 with that check named and nothing else,
  and the body never carries a tenant, a user or a count. Then the healthy answer. Last, the
  SigNoz SLO files: every rule filters on a path this endpoint serves and a metric the
  application reports.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0]

  alias AshEnterpriseWeb.Plugs.Health

  @slo Path.expand("../../devenv/observability/slo", __DIR__)

  @keys ["checks", "status", "version"]

  test "a request with no session or credentials is answered, and no cookie is set", %{conn: conn} do
    conn = get(conn, "/health")

    assert conn.status == 200
    assert get_resp_header(conn, "set-cookie") == []
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
  end

  test "only GET and HEAD on /health itself are answered here", %{conn: conn} do
    for path <- ["/health/x", "/healthz", "/api/health"] do
      refute Health.call(build_conn(:get, path), []).halted
    end

    refute Health.call(build_conn(:post, "/health"), []).halted

    head = head(conn, "/health")
    assert head.status == 200
  end

  test "a failing check answers 503, names the check and says nothing else" do
    failing = [
      repo: fn -> {:error, %RuntimeError{message: "secret detail"}} end,
      oban: fn -> :ok end
    ]

    conn = Health.call(build_conn(:get, "/health"), checks: failing)

    assert conn.status == 503
    body = Jason.decode!(conn.resp_body)
    assert Map.keys(body) |> Enum.sort() == @keys
    assert body["status"] == "unavailable"
    assert body["checks"] == %{"repo" => "down", "oban" => "ok"}
    refute conn.resp_body =~ "secret detail"

    raising = [repo: fn -> raise "boom" end, oban: fn -> exit(:gone) end]
    conn = Health.call(build_conn(:get, "/health"), checks: raising)
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["checks"] == %{"repo" => "down", "oban" => "down"}
  end

  test "the body carries no tenant, user or data, whatever the database holds", %{conn: conn} do
    ctx = tenant!()
    conn = get(conn, "/health")
    body = Jason.decode!(conn.resp_body)

    assert Enum.sort(Map.keys(body)) == @keys
    assert Enum.sort(Map.keys(body["checks"])) == ["oban", "repo"]
    assert is_binary(body["version"])

    for value <- [ctx.tenant, ctx.user.id, to_string(ctx.user.email)] do
      refute conn.resp_body =~ value
    end
  end

  test "a healthy node answers 200 with every check ok", %{conn: conn} do
    body = conn |> get("/health") |> json_response(200)

    assert body["status"] == "ok"
    assert body["checks"] == %{"repo" => "ok", "oban" => "ok"}
    assert body["version"] == to_string(Application.spec(:ash_enterprise, :vsn))
  end

  test "every SLO rule filters on /health or a metric the application reports" do
    metrics =
      AshEnterprise.Telemetry.Metrics.standard(ash_domains: [AshEnterprise.Automation])
      |> Enum.map(&Enum.join(&1.name, "."))
      |> MapSet.new()

    files = Path.wildcard(Path.join(@slo, "{alerts,dashboards}/*.json"))
    assert length(files) == 5

    for file <- files do
      text = File.read!(file)
      _json = Jason.decode!(text)

      for [path] <- Regex.scan(~r/url\.path = '([^']+)'/, text, capture: :all_but_first) do
        assert path == "/health", "#{file} filters on #{path}"
      end

      for [name] <- Regex.scan(~r/"metricName": "([^"]+)\.bucket"/, text, capture: :all_but_first) do
        assert name in metrics, "#{file} names #{name}, which no metric reports"
      end

      assert text =~ "/health" or text =~ "metricName", "#{file} measures nothing"
    end
  end
end
