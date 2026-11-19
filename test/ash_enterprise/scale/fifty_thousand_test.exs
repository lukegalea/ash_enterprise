defmodule AshEnterprise.Scale.FiftyThousandTest do
  @moduledoc """
  The scale budget: a page costs the same at 1,000 rows as at 50,000.

  One tenant is seeded with 1,000 teams, every measured read runs, the tenant
  grows to 50,000 teams (`SCALE_ROWS` overrides the count), and every read runs
  again. Teams are audited, so the seed goes through the audit chain, and they are
  business-owned, so a business-unit-depth role reads them through the grant
  union. A telemetry handler counts the repo queries each read issues.

  The measured reads: an unpaged JSON:API index, the keyset page its `next` link
  names, an unpaged GraphQL list, and the `:list` read by a member whose only
  grant is a local-depth team read. The bulk export (`GET /api/exports/teams`) then
  writes all 50,000 rows in keyset pages, and its time is printed.

  Tagged `:scale` and excluded from the suite; CI runs it as its own job
  (`mix test --only scale`). The numbers are this fixture on CI hardware, not a
  claim about any deployment. SYNTHETIC data only.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias AshEnterprise.Accounts.Team
  alias AshEnterprise.Test.DailyFixtures

  @moduletag :scale
  @moduletag timeout: :infinity

  @endpoint AshEnterpriseWeb.Endpoint

  @small 1_000
  @rows "SCALE_ROWS" |> System.get_env("50000") |> String.to_integer()

  # Wall-clock ceilings in milliseconds for one read at full size: three times the
  # first CI measurement (ubuntu-latest, run 43579714022: index 83ms, next page 83ms,
  # GraphQL list 59ms, depth-role read 25ms), recorded in the q44 answer.
  @ceilings %{
    json_api_index: 249,
    json_api_next: 249,
    graphql_list: 177,
    depth_role: 75
  }

  setup_all do
    # One sandbox transaction holds the whole seed, rolled back when the module ends.
    # The seed outlasts the default two-minute ownership timeout on a CI runner.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(AshEnterprise.Repo,
        shared: true,
        ownership_timeout: :infinity
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    admin = DailyFixtures.tenant!()

    reader =
      DailyFixtures.member!(admin, "Local team reader", [{Team, :read, :local}])

    {seed_small_ms, :ok} = timed(fn -> DailyFixtures.teams!(admin, @small, prefix: "Scale") end)
    IO.puts("[scale] seeded #{@small} teams in #{seed_small_ms}ms")
    small = measure_all(admin, reader)

    {seed_rest_ms, :ok} =
      timed(fn ->
        DailyFixtures.teams!(admin, @rows - @small, prefix: "Scale", from: @small + 1)
      end)

    large = measure_all(admin, reader)

    report(small, large, seed_small_ms, seed_rest_ms)

    %{admin: admin, reader: reader, small: small, large: large}
  end

  test "query count for a page is the same at 1k and 50k rows", %{small: small, large: large} do
    for {read, at_small} <- small do
      at_large = Map.fetch!(large, read)

      assert at_small.rows == at_large.rows and at_large.rows == 50,
             "#{read} returned #{at_small.rows} then #{at_large.rows} rows"

      assert at_small.queries == at_large.queries,
             "#{read}: #{length(at_small.queries)} queries at #{@small}, " <>
               "#{length(at_large.queries)} at #{@rows}\n#{inspect(at_large.queries)}"
    end
  end

  test "a business-unit-scoped role's page issues no policy queries (ActorContext precomputed)",
       %{reader: reader, large: large} do
    # The actor carries its context; the read is one query on teams, nothing on the
    # role, privilege, business-unit or membership tables.
    assert %{queries: ["teams"], rows: 50} = Map.fetch!(large, :depth_role)

    {page, sources} = counting(fn -> depth_read(reader) end)
    assert length(page.results) == 50
    assert sources == ["teams"]
  end

  test "each measured read stays under its ceiling", %{large: large} do
    for {read, %{ms: ms}} <- large do
      ceiling = Map.fetch!(@ceilings, read)
      assert ms <= ceiling, "#{read} took #{ms}ms at #{@rows} rows; the ceiling is #{ceiling}ms"
    end
  end

  # The bulk export out (`GET /api/exports/teams`, AshEnterprise.Exports.Csv) over the
  # same 50,000 teams: every row, in keyset pages of 250, never the set in memory. The
  # wall-clock time is printed for the q42 answer and docs/runbooks/exports.md, not
  # asserted.
  test "streams 50_000 rows in keyset pages without loading the set", %{admin: admin} do
    total = Ash.count!(Team, tenant: admin.tenant, authorize?: false)
    assert total >= @rows

    key =
      AshEnterprise.Accounts.ApiKey
      |> Ash.Changeset.for_create(
        :issue,
        %{
          user_id: admin.user.id,
          name: "scale export",
          expires_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        authorize?: false
      )
      |> Ash.create!()
      |> then(& &1.__metadata__.plaintext_api_key)

    {ms, {conn, sources}} =
      timed(fn ->
        counting(fn ->
          build_conn()
          |> put_req_header("authorization", "Bearer " <> key)
          |> get("/api/exports/teams")
        end)
      end)

    assert conn.status == 200
    assert conn.state == :chunked

    # The header and one line per team.
    lines = :binary.matches(conn.resp_body, "\r\n") |> length()
    assert lines == total + 1

    # One bounded read of teams per page of 250: as many reads as pages, never one.
    team_reads = Enum.count(sources, &(&1 == "teams"))
    assert team_reads >= div(total, AshEnterprise.Exports.Csv.batch_size())

    # Bounded memory: the reading process, collected after each page, never holds
    # more than a page or so. Fifty thousand loaded records would hold far more.
    peak = peak_stream_memory(admin)
    assert peak < 32 * 1024 * 1024, "the stream held #{peak} bytes at its peak"

    IO.puts(
      "[scale] export of #{total} teams: #{ms}ms, #{byte_size(conn.resp_body)} bytes, " <>
        "#{team_reads} team reads, peak #{div(peak, 1024)}KB while streaming"
    )
  end

  defp peak_stream_memory(admin) do
    Team
    |> AshEnterprise.Exports.Csv.stream(actor: admin.actor, tenant: admin.tenant)
    |> Stream.chunk_every(AshEnterprise.Exports.Csv.batch_size())
    |> Enum.reduce(0, fn _lines, peak ->
      :erlang.garbage_collect()
      {:memory, bytes} = Process.info(self(), :memory)
      max(peak, bytes)
    end)
  end

  # --- the reads ---------------------------------------------------------------

  defp measure_all(admin, reader) do
    index = fn -> admin.user |> bearer() |> get("/api/json/teams") |> json_response(200) end
    first = index.()
    next_path = first["links"]["next"] |> URI.parse() |> then(&"#{&1.path}?#{&1.query}")

    graphql = fn ->
      admin.user
      |> bearer()
      |> post("/gql", %{query: "{ listTeams { results { id name } } }"})
      |> json_response(200)
      |> get_in(["data", "listTeams", "results"])
    end

    %{
      json_api_index: measure(index, &length(&1["data"])),
      json_api_next:
        measure(
          fn -> admin.user |> bearer() |> get(next_path) |> json_response(200) end,
          &length(&1["data"])
        ),
      graphql_list: measure(graphql, &length/1),
      depth_role: measure(fn -> depth_read(reader) end, &length(&1.results))
    }
  end

  defp depth_read(reader) do
    Team
    |> Ash.Query.for_read(:list, %{}, actor: reader.actor, tenant: reader.tenant)
    |> Ash.read!()
  end

  # One warm-up, then the median of three timed runs; the queries of the last.
  defp measure(fun, count_rows) do
    fun.()

    runs = for _ <- 1..3, do: timed(fn -> counting(fun) end)
    {_, {result, queries}} = List.last(runs)
    ms = runs |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.at(1)

    %{ms: ms, queries: queries, rows: count_rows.(result)}
  end

  defp timed(fun) do
    {micros, result} = :timer.tc(fun)
    {div(micros, 1000), result}
  end

  # The sources of the repo queries `fun` issues, from this process or a task it
  # started; other processes share the sandbox connection and are not counted.
  defp counting(fun) do
    test = self()
    ref = make_ref()
    id = "scale-#{inspect(ref)}"

    :telemetry.attach(
      id,
      [:ash_enterprise, :repo, :query],
      fn _event, _measurements, meta, _ ->
        if self() == test or test in (Process.get(:"$callers") || []) do
          send(test, {ref, meta[:source] || "(no source)"})
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(id)
      end

    {result, drain(ref, [])}
  end

  defp drain(ref, acc) do
    receive do
      {^ref, source} -> drain(ref, [source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp bearer(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp report(small, large, seed_small_ms, seed_rest_ms) do
    lines =
      for {read, at_large} <- Enum.sort(large) do
        at_small = Map.fetch!(small, read)

        "  #{read}: #{length(at_small.queries)} queries / #{at_small.ms}ms at #{@small}, " <>
          "#{length(at_large.queries)} queries / #{at_large.ms}ms at #{@rows}"
      end

    IO.puts("""

    [scale] seeded #{@small} teams in #{seed_small_ms}ms, #{@rows - @small} more in #{seed_rest_ms}ms
    #{Enum.join(lines, "\n")}
    """)
  end
end
