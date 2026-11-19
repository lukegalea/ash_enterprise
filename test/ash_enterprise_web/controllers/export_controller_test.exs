defmodule AshEnterpriseWeb.ExportControllerTest do
  @moduledoc """
  `GET /api/exports/:type` through the real router and pipeline, with real API
  keys: the door (no key, a refused key), the export privilege, the exportable
  set, the tenant, the reader's grants, and the shape of the stream itself (keyset
  pages, chunked, counted by telemetry). The 50,000-row run is in the scale job
  (test/ash_enterprise/scale/export_stream_test.exs). SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  alias AshEnterprise.Accounts.{ApiKey, BusinessUnit, Team}
  alias AshEnterprise.Exports.Export
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.DailyFixtures

  defp key!(user) do
    ApiKey
    |> Ash.Changeset.for_create(
      :issue,
      %{user_id: user.id, name: "export", expires_at: DateTime.add(DateTime.utc_now(), 3600)},
      authorize?: false
    )
    |> Ash.create!()
    |> then(& &1.__metadata__.plaintext_api_key)
  end

  defp export(type, key) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> key)
    |> get("/api/exports/#{type}")
  end

  # The CSV as a header and maps of its rows. The fixture's values hold no comma,
  # quote or newline, so a plain split reads them.
  defp parse(body) do
    [header | lines] = String.split(body, "\r\n", trim: true)
    columns = String.split(header, ",")
    {columns, Enum.map(lines, &(columns |> Enum.zip(String.split(&1, ",")) |> Map.new()))}
  end

  defp names(conn) do
    {_columns, rows} = parse(conn.resp_body)
    rows |> Enum.map(& &1["name"]) |> MapSet.new()
  end

  defp exporter!(admin, grants) do
    role = "Exporter #{System.unique_integer([:positive])}"
    DailyFixtures.member!(admin, role, [{Export, :read, :global} | grants])
  end

  defp teams_in!(admin, unit_id, names) do
    %Ash.BulkResult{status: :success} =
      names
      |> Enum.map(&%{name: &1, owning_business_unit_id: unit_id})
      |> Ash.bulk_create!(Team, :create,
        tenant: admin.tenant,
        actor: SystemActor.seed(),
        authorize?: false,
        return_errors?: true,
        stop_on_error?: true
      )
  end

  defp names_for(prefix, count), do: for(n <- 1..count, do: "#{prefix} #{n}")

  describe "refused" do
    test "no bearer key answers 401 and writes no rows" do
      admin = DailyFixtures.tenant!()
      DailyFixtures.teams!(admin, 3, prefix: "Unseen")

      conn = get(build_conn(), "/api/exports/teams")
      assert conn.status == 401
      assert %{"error" => "unauthenticated"} = Jason.decode!(conn.resp_body)
      refute conn.resp_body =~ "Unseen"

      refused = export("teams", "aek_not-a-key")
      assert refused.status == 401
      refute refused.resp_body =~ "Unseen"
    end

    test "a key whose user lacks the export privilege is refused 403" do
      admin = DailyFixtures.tenant!()
      DailyFixtures.teams!(admin, 3, prefix: "Unseen")
      reader = DailyFixtures.member!(admin, "Team reader", [{Team, :read, :global}])

      conn = export("teams", key!(reader.user))
      assert conn.status == 403
      assert %{"error" => "forbidden"} = Jason.decode!(conn.resp_body)
      refute conn.resp_body =~ "Unseen"

      # The privilege is checked before the type: an unknown type tells them nothing.
      assert export("roles", key!(reader.user)).status == 403
    end

    test "a type that is not exportable answers 404" do
      admin = DailyFixtures.tenant!()
      key = key!(admin.user)

      for type <- ~w(roles users event_logs privileges api_keys Team) do
        conn = export(type, key)
        assert conn.status == 404, "#{type} answered #{conn.status}"
        assert %{"error" => "not_exportable"} = Jason.decode!(conn.resp_body)
      end
    end

    test "a system actor cannot open an export: opening one is a person's act" do
      assert {:error, %Ash.Error.Forbidden{}} =
               AshEnterprise.Exports.open_export("teams", actor: SystemActor.seed())
    end

    test "another tenant's rows never appear in the export" do
      ours = DailyFixtures.tenant!()
      theirs = DailyFixtures.tenant!()
      DailyFixtures.teams!(ours, 5, prefix: "Ours")
      DailyFixtures.teams!(theirs, 5, prefix: "Theirs")

      conn = export("teams", key!(ours.user))
      assert conn.status == 200

      {_columns, rows} = parse(conn.resp_body)
      assert MapSet.subset?(MapSet.new(names_for("Ours", 5)), names(conn))
      refute Enum.any?(rows, &String.starts_with?(&1["name"], "Theirs"))
      assert Enum.all?(rows, &(&1["organization_id"] == ours.tenant))
    end

    test "a reader sees only the rows their grants reach (a :local grant exports its business unit only)" do
      admin = DailyFixtures.tenant!()
      root = admin.user.owning_business_unit_id

      child =
        BusinessUnit
        |> Ash.Changeset.for_create(:create, %{name: "Branch", parent_business_unit_id: root},
          authorize?: false,
          tenant: admin.tenant,
          actor: SystemActor.seed()
        )
        |> Ash.create!()

      teams_in!(admin, root, names_for("Root", 4))
      teams_in!(admin, child.id, names_for("Branch", 4))

      # In the root unit, with a local team read: the root's teams, not the branch's.
      local = exporter!(admin, [{Team, :read, :local}])
      conn = export("teams", key!(local.user))
      assert conn.status == 200

      exported = names(conn)
      assert MapSet.subset?(MapSet.new(names_for("Root", 4)), exported)
      assert MapSet.disjoint?(MapSet.new(names_for("Branch", 4)), exported)

      # The export privilege alone reaches no rows: a header and nothing else.
      bare = exporter!(admin, [])
      conn = export("teams", key!(bare.user))
      assert conn.status == 200
      assert {columns, []} = parse(conn.resp_body)
      assert "name" in columns
    end
  end

  test "the administrator exports the tenant's teams as CSV, header first" do
    admin = DailyFixtures.tenant!()
    DailyFixtures.teams!(admin, 3, prefix: "Listed")

    conn = export("teams", key!(admin.user))
    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/csv"
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="teams.csv")]

    {columns, _rows} = parse(conn.resp_body)
    assert columns == Enum.map(AshEnterprise.Exports.Csv.columns(Team), &Atom.to_string/1)
    assert MapSet.subset?(MapSet.new(names_for("Listed", 3)), names(conn))
    refute "hashed_password" in columns
  end

  test "streams the rows in keyset pages, one chunk per page, and reports the count" do
    admin = DailyFixtures.tenant!()
    DailyFixtures.teams!(admin, 600, prefix: "Paged")
    total = Ash.count!(Team, tenant: admin.tenant, authorize?: false)
    key = key!(admin.user)

    test = self()
    id = "export-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [[:ash_enterprise, :repo, :query], [:ash_enterprise, :exports, :csv, :stop]],
      fn
        [:ash_enterprise, :repo, :query], _measurements, %{source: "teams", query: sql}, _ ->
          send(test, {:teams_query, sql})

        [:ash_enterprise, :exports, :csv, :stop], measurements, meta, _ ->
          send(test, {:export_stop, measurements, meta})

        _event, _measurements, _meta, _ ->
          :ok
      end,
      nil
    )

    conn =
      try do
        export("teams", key)
      after
        :telemetry.detach(id)
      end

    assert conn.status == 200
    assert conn.state == :chunked

    {_columns, rows} = parse(conn.resp_body)
    assert length(rows) == total

    # Every page is a bounded read of at most one batch (plus the one-row lookahead
    # Ash keyset uses), and there are as many as the rows need: never one read of the
    # whole set.
    pages = drain_queries([])
    assert length(pages) >= div(total, 250) + 1
    assert Enum.all?(pages, &(&1 =~ "LIMIT"))

    assert_received {:export_stop, %{duration: duration}, %{type: "teams", rows: ^total} = meta}
    assert is_integer(duration)
    assert Map.keys(meta) |> Enum.sort() == [:rows, :telemetry_span_context, :type]
  end

  defp drain_queries(acc) do
    receive do
      {:teams_query, sql} -> drain_queries([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
