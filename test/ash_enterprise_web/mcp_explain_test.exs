defmodule AshEnterpriseWeb.McpExplainTest do
  @moduledoc """
  The assistant's `explain` tool on `/mcp`, given the address of a value (ADR 0078):
  it answers what `AshEnterprise.Provenance.explain/2` answers, as rows, behind the
  `ont_why` flag, and never carries the value itself. What must not happen comes
  first: the flag off, a reader told more than the code interface tells them, a value
  in a row, an unreadable subject told apart from a missing one, and the record form
  of the tool opening for a caller that is not an agent run.

  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, actor: 1]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Flags
  alias AshEnterprise.Provenance
  alias AshEnterprise.Provenance.Why

  @title "SYNTHETIC-TITLE the sentence only the page may show"

  setup do
    admin = tenant!()
    writer = member!(admin, "Writer", [])

    reader =
      member!(admin, "Reader", [
        {Task, :read, :global},
        {EventLog, :read, :global},
        {User, :read, :global}
      ])

    outsider = member!(admin, "Outsider", [{EventLog, :read, :global}, {User, :read, :global}])
    task = Task.capture!(@title, %{}, actor: writer.actor, tenant: admin.tenant)

    %{admin: admin, reader: reader, outsider: outsider, task: task}
  end

  defp turn_on!(admin, key \\ "ont_why"),
    do: Flags.set_flag!(key, %{state: :on}, actor: admin.actor, tenant: admin.tenant)

  defp address(task, attribute \\ "title"),
    do: "#{Provenance.base()}/task/#{task.id}##{attribute}"

  defp call_tool(conn, user, arguments) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "explain", "arguments" => %{"input" => arguments}}
    })
  end

  # The tool's answer: its rows, or the refusal's text.
  defp answer(conn) do
    case json_response(conn, 200) do
      %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} ->
        {:rows, JSON.decode!(text)}

      %{"result" => %{"isError" => true} = result} ->
        {:error, JSON.encode!(result)}
    end
  end

  defp rows!({:rows, rows}), do: List.wrap(rows)

  describe "what the tool refuses" do
    test "a flag that is off offers nothing", %{conn: conn, reader: reader, task: task} do
      assert {:error, text} =
               conn |> call_tool(reader.user, %{"address" => address(task)}) |> answer()

      assert text =~ "not turned on"
    end

    test "the flag is only an offer: it gives a reader without the grant nothing", %{
      conn: conn,
      admin: admin,
      outsider: outsider,
      task: task
    } do
      turn_on!(admin)

      rows =
        conn |> call_tool(outsider.user, %{"address" => address(task)}) |> answer() |> rows!()

      # The outsider cannot read the task: the answer is the one for no such value.
      assert [%{"role" => "missing", "missing" => missing}] = rows
      assert missing =~ "that you may read"
    end

    test "an unreadable subject reads as one that does not exist", %{
      conn: conn,
      admin: admin,
      outsider: outsider,
      task: task
    } do
      turn_on!(admin)
      absent = %{task | id: Ash.UUID.generate()}

      unreadable =
        conn |> call_tool(outsider.user, %{"address" => address(task)}) |> answer() |> rows!()

      missing =
        build_conn()
        |> call_tool(outsider.user, %{"address" => address(absent)})
        |> answer()
        |> rows!()

      strip = fn [%{"missing" => text}] ->
        String.replace(text, ~r/task\/[0-9a-f-]{36}/, "task/ID")
      end

      assert strip.(unreadable) == strip.(missing)
    end

    test "a ref and an address together are refused, and neither is the record form", %{
      conn: conn,
      admin: admin,
      reader: reader,
      task: task
    } do
      turn_on!(admin)

      assert {:error, text} =
               conn
               |> call_tool(reader.user, %{
                 "address" => address(task),
                 "ref" => "run:00000000-0000-0000-0000-000000000000"
               })
               |> answer()

      assert text =~ "not both"

      # Neither is the record form of the tool, which an MCP client is refused.
      assert {:error, text} = build_conn() |> call_tool(reader.user, %{}) |> answer()
      assert text =~ "Refused"
    end

    test "a record's ref is still the zone gate's: an MCP client is not an agent run", %{
      conn: conn,
      admin: admin,
      reader: reader
    } do
      turn_on!(admin)

      assert {:error, text} =
               conn
               |> call_tool(reader.user, %{"ref" => "run:00000000-0000-0000-0000-000000000000"})
               |> answer()

      assert text =~ "Refused"
    end
  end

  describe "what the tool answers" do
    test "the code interface's answer, step for step, and not the value", %{
      conn: conn,
      admin: admin,
      reader: reader,
      task: task
    } do
      turn_on!(admin)

      {:ok, %{explanation: explanation, correlation_ids: correlation_ids}} =
        Provenance.explain(address(task),
          actor: actor(Ash.reload!(reader.user, authorize?: false)),
          tenant: admin.tenant
        )

      expected = Why.rows(explanation, correlation_ids)
      assert Enum.any?(expected, &(&1.relation == :was_generated_by))

      conn = call_tool(conn, reader.user, %{"address" => address(task)})
      body = conn.resp_body
      rows = conn |> answer() |> rows!()

      assert length(rows) == length(expected)

      for {row, want} <- Enum.zip(rows, expected) do
        assert row["kind"] == Atom.to_string(want.relation)
        assert row["meaning"] == want.what
        assert row["by"] == want[:by]
        assert row["at"] == want[:at]
        assert row["summary"] == want[:summary]
        assert row["correlation_id"] == want[:correlation_id]
        refute Map.has_key?(row, "value")
      end

      # The page shows what was set; the tool never does.
      refute body =~ @title
    end
  end
end
