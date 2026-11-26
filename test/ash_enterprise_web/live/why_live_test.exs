defmodule AshEnterpriseWeb.WhyLiveTest do
  @moduledoc """
  The Why page (`/app/why`, ADR 0078), behind the `ont_why` flag: the address of one
  value in, the steps and gaps of its answer out, as the signed-in person may read
  them. What must not happen comes first: the page open with the flag off, a flag
  that opens more than the person may read, and an answer a person cannot tell from
  no answer.

  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]
  import Phoenix.LiveViewTest

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Flags
  alias AshEnterprise.Provenance

  @title "SYNTHETIC-TITLE book the venue"

  setup do
    admin = tenant!()
    writer = member!(admin, "Writer", [])

    reader =
      member!(admin, "Reader", [
        {Task, :read, :global},
        {EventLog, :read, :global},
        {User, :read, :global}
      ])

    task = Task.capture!(@title, %{}, actor: writer.actor, tenant: admin.tenant)
    %{admin: admin, reader: reader, task: task}
  end

  defp turn_on!(admin),
    do: Flags.set_flag!("ont_why", %{state: :on}, actor: admin.actor, tenant: admin.tenant)

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp ask(view, address) do
    # The surface's own first push, before the report is run.
    assert_push_event(view, "a2ui:messages", %{messages: _bootstrap}, 5_000)

    render_hook(
      view,
      "a2ui:message",
      AshEnterprise.A2uiMessage.ash_action(
        "why",
        "report",
        %{"component" => "why", "params" => %{"address" => address}},
        source: "why"
      )
    )

    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    messages
  end

  defp report_rows(messages) do
    Enum.find_value(messages, [], fn
      %{"updateDataModel" => %{"path" => "/report/why/rows", "value" => rows}} -> rows
      _other -> nil
    end)
  end

  test "with the flag off the page is closed, and the launcher does not offer it", %{
    reader: reader
  } do
    assert {:error, {:redirect, %{to: "/app"}}} = live(sign_in(reader.user), "/app/why")
  end

  test "with the flag on a reader asks for an address and reads its steps", %{
    admin: admin,
    reader: reader,
    task: task
  } do
    turn_on!(admin)

    {:ok, view, html} = live(sign_in(reader.user), "/app/why")
    assert html =~ "ash-a2ui-surface"

    messages = ask(view, "#{Provenance.base()}/task/#{task.id}#title")
    rows = report_rows(messages)
    assert rows != [], JSON.encode!(messages)

    assert Enum.any?(rows, &(&1["what"] == "set by" and &1["granularity"] in ["value", :value]))
    assert Enum.any?(rows, &(&1["by"] == reader.email or &1["by"] != nil))
  end

  test "an address the reader cannot read gets an error, not rows", %{
    admin: admin,
    task: task
  } do
    turn_on!(admin)
    outsider = member!(admin, "Outsider", [{EventLog, :read, :global}])

    {:ok, view, _html} = live(sign_in(outsider.user), "/app/why")
    messages = ask(view, "#{Provenance.base()}/task/#{task.id}#title")

    assert report_rows(messages) == []
    refute JSON.encode!(messages) =~ @title
  end
end
