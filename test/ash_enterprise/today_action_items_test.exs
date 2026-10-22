defmodule AshEnterprise.TodayActionItemsTest do
  @moduledoc """
  The morning brief's "today" section (PROD-18): Today's surface lists the
  person's own open action items planned for today or due by tonight, each
  linked to its card on Action items; the `today` digest says them; the
  pulse counts today's items and the unsorted ones. Nobody else's items
  appear.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Agents.Today
  alias AshEnterprise.Canonical.Task
  alias AshEnterpriseWeb.A2ui.TodayUI

  setup do
    admin = tenant!()
    me = member!(admin, "Nobody special", [])
    other = member!(admin, "Someone else", [])
    opts = [actor: me.actor, tenant: me.tenant]

    planned = Task.capture!("Call the accountant", %{}, opts)
    {:ok, _} = Task.plan_today_mine(planned.id, opts)

    overdue =
      Task.capture!("Expense report", %{due_at: DateTime.add(DateTime.utc_now(), -1, :day)}, opts)

    later = Task.capture!("Plan the offsite", %{}, opts)
    {:ok, _} = Task.plan_later_mine(later.id, opts)
    _unsorted = Task.capture!("Look into the new CRM", %{}, opts)

    Task.capture!("Their errand", %{}, actor: other.actor, tenant: other.tenant)
    |> then(&Task.plan_today_mine(&1.id, actor: other.actor, tenant: other.tenant))

    %{me: me, opts: opts, planned: planned, overdue: overdue, later: later}
  end

  test "Today's surface lists today's own items, linked to Action items", ctx do
    %{"updateDataModel" => %{"value" => value}} =
      AshA2ui.Info.build_data_model(TodayUI, actor: ctx.me.actor, tenant: ctx.me.tenant)

    rows = value["records"]["today_items"]
    assert Enum.map(rows, & &1["id"]) == [ctx.overdue.id, ctx.planned.id]
    assert Enum.find(rows, &(&1["id"] == ctx.overdue.id))["due"] =~ "overdue"

    assert %{"surface" => "action_items", "recordId" => id} =
             hd(rows)["_links"]["title"]

    assert id == ctx.overdue.id
  end

  test "the today digest has a section for them; the pulse counts them", ctx do
    {:ok, digest} = Today.digest(ctx.opts)
    assert digest =~ "Today's action items — 2."
    assert digest =~ "  - Expense report"
    assert digest =~ "  - Call the accountant"
    refute digest =~ "Plan the offsite"
    refute digest =~ "Their errand"

    {:ok, pulse} = Today.pulse(ctx.opts)

    assert %{value: "2 for today · 1 in your inbox"} =
             Enum.find(pulse, &(&1.signal == "Action items"))
  end
end
