defmodule AshEnterpriseWeb.ActionItemsLiveTest do
  @moduledoc """
  Action items (`/app/action-items`, PROD-18) through the real LiveView, as
  the signed-in person clicks it: capture an item, see it in Inbox, move it
  to Today, finish it; a brief approval waiting on them appears beside the
  board, linked to the task, to the brief and to its run; another person's
  item is neither shown nor movable.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Agents.BriefDecision
  alias AshEnterprise.Canonical.Task

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp pushed(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    messages
  end

  defp action(view, name, context) do
    render_hook(view, "a2ui:action", %{
      "version" => "v1.0",
      "action" => %{
        "name" => name,
        "surfaceId" => "action_items",
        "sourceComponentId" => "action_items",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "context" => context
      }
    })

    pushed(view)
  end

  defp invoke(view, action_name, task, lane) do
    action(view, "invoke", %{
      "action" => action_name,
      "recordId" => task.id,
      "component" => "board_#{lane}"
    })
  end

  # Every row the messages carry, by table: the bootstrap's data model, or a
  # refresh's per-table `/records/<table>` updates.
  defp rows(messages) do
    Enum.reduce(messages, %{}, fn
      %{"createSurface" => %{"dataModel" => %{"records" => records}}}, acc ->
        Map.merge(acc, Map.filter(records, fn {_table, rows} -> is_list(rows) end))

      %{"updateDataModel" => %{"path" => "/records/" <> table, "value" => rows}}, acc
      when is_list(rows) ->
        Map.put(acc, table, rows)

      %{"updateDataModel" => %{"path" => "/records", "value" => %{} = records}}, acc ->
        Map.merge(acc, Map.filter(records, fn {_table, rows} -> is_list(rows) end))

      _other, acc ->
        acc
    end)
  end

  defp ids(rows, table), do: rows |> Map.get(table, []) |> Enum.map(& &1["id"])

  defp feedback(messages) do
    Enum.find_value(messages, fn
      %{"updateDataModel" => %{"path" => "/ui/feedback", "value" => value}} -> value
      _other -> nil
    end)
  end

  setup %{conn: conn} do
    ctx = tenant!()
    %{conn: sign_in(conn, ctx.user), ctx: ctx}
  end

  test "capture an item, see it in Inbox, move it to Today, finish it", %{conn: conn, ctx: ctx} do
    {:ok, view, _html} = live(conn, "/app/action-items")
    assert has_element?(view, "#nav-action_items[aria-current=page]")
    bootstrap = pushed(view)
    assert ids(rows(bootstrap), "board_inbox") == []

    captured =
      action(view, "submit_form", %{"values" => %{"title" => "Send Dana the Q3 deck"}})

    assert [task] = Task.mine!(actor: ctx.actor, tenant: ctx.tenant)
    assert task.title == "Send Dana the Q3 deck"
    assert task.source == "manual"
    assert task.id in ids(rows(captured), "board_inbox")

    moved = invoke(view, "plan_today_mine", task, "inbox")
    assert task.id in ids(rows(moved), "board_today")
    refute task.id in ids(rows(moved), "board_inbox")

    finished = invoke(view, "complete_mine", task, "today")
    assert task.id in ids(rows(finished), "board_done")
    refute task.id in ids(rows(finished), "board_today")

    assert %Task{status: :done, plan: :today} =
             Ash.get!(Task, task.id, tenant: ctx.tenant, authorize?: false)
  end

  test "a brief approval waiting on the person appears beside the board, linked", %{
    conn: conn,
    ctx: ctx
  } do
    brief = brief!(ctx)
    {:ok, approval} = BriefDecision.open_task(brief, actor: ctx.actor, tenant: ctx.tenant)

    {:ok, view, _html} = live(conn, "/app/action-items")
    assert [row] = rows(pushed(view))["waiting"]

    assert row["id"] == approval.id
    assert row["subject_label"] =~ "Morning brief"

    links = row["_links"]
    assert %{"surface" => "tasks", "recordId" => task_id} = links["name"]
    assert task_id == approval.id
    assert %{"surface" => "record", "recordId" => "today:" <> brief_id} = links["subject_label"]
    assert brief_id == brief.id
    assert %{"surface" => "flight", "recordId" => instance_id} = links["run_stage"]
    assert instance_id == approval.instance_id

    # A feed, not a copy: nothing was written into the person's list.
    assert Task.mine!(actor: ctx.actor, tenant: ctx.tenant) == []
  end

  test "a proposal waits in Proposed, in its own words, until the person accepts it", %{
    conn: conn,
    ctx: ctx
  } do
    %{message: message, conversation: conversation} =
      AshEnterprise.Test.CommitmentFixtures.sent!(ctx, "gmail", "I'll book the venue today")

    proposal =
      Task.propose!(
        %{
          commitment: "Book the venue",
          evidence: "I'll book the venue today",
          source: "gmail",
          origin_type: to_string(AshEnterprise.Canonical.Conversation),
          origin_id: conversation.id,
          external_system: "commitment",
          external_id: "live-test:#{message.id}",
          erasure_scope_id: message.erasure_scope_id,
          proposer: "message_commitments/1",
          instrument: "synthetic",
          owner_id: ctx.user.id,
          owning_user_id: ctx.user.id,
          owning_business_unit_id: ctx.user.owning_business_unit_id
        },
        actor: AshEnterprise.Platform.SystemActor.proposer(),
        tenant: ctx.tenant
      )

    {:ok, view, _html} = live(conn, "/app/action-items")
    assert [card] = rows(pushed(view))["board_proposed"]
    assert card["id"] == proposal.id
    assert card["label"] == "Book the venue"

    assert %{"surface" => "record", "recordId" => "inbox:" <> conv_id} =
             card["_links"]["origin_label"]

    assert conv_id == conversation.id

    accepted = invoke(view, "accept_mine", proposal, "proposed")
    assert proposal.id in ids(rows(accepted), "board_inbox")
    refute proposal.id in ids(rows(accepted), "board_proposed")

    assert %Task{status: :open} =
             Ash.get!(Task, proposal.id, tenant: ctx.tenant, authorize?: false)
  end

  test "another person's item is not on the board and cannot be moved", %{conn: conn, ctx: ctx} do
    other = member!(ctx, "Colleague", [])
    theirs = Task.capture!("Their private errand", %{}, actor: other.actor, tenant: other.tenant)

    {:ok, view, _html} = live(conn, "/app/action-items")
    board = rows(pushed(view))
    refute theirs.id in (board |> Map.values() |> List.flatten() |> Enum.map(& &1["id"]))

    refused = invoke(view, "complete_mine", theirs, "inbox")
    assert %{"kind" => "error"} = feedback(refused)

    assert %Task{status: :open} = Ash.get!(Task, theirs.id, tenant: ctx.tenant, authorize?: false)
  end
end
