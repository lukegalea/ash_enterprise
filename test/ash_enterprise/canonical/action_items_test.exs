defmodule AshEnterprise.Canonical.ActionItemsTest do
  @moduledoc """
  A person's own action items (`Canonical.Task`, PROD-18) as a member with no
  role grant at all would use them: capture into the Inbox, move between
  lanes, finish, reopen and drop — each the self-service action, owner-only
  (ADR 0052). Another member's task is not found, whatever they try, and a
  move from the wrong status is refused by the update itself.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.LocalTime

  setup do
    admin = tenant!()
    %{me: member!(admin, "Nobody special", []), other: member!(admin, "Someone else", [])}
  end

  defp opts(person), do: [actor: person.actor, tenant: person.tenant, authorize?: true]

  defp capture!(person, title, extra \\ %{}),
    do: Task.capture!(title, extra, opts(person))

  defp lane(person, task) do
    {:ok, [found]} = Task.mine(Keyword.put(opts(person), :query, filter: [id: task.id]))
    found |> Ash.load!(:lane, opts(person)) |> Map.fetch!(:lane)
  end

  test "a member with no grants captures, plans, finishes and reopens their own item", %{me: me} do
    task = capture!(me, "Send Dana the Q3 deck")
    assert task.status == :open
    assert task.plan == :inbox
    assert task.source == "manual"
    assert lane(me, task) == :inbox

    assert {:ok, %Task{plan: :today}} = Task.plan_today_mine(task.id, opts(me))
    assert lane(me, task) == :today

    assert {:ok, %Task{plan: :later}} = Task.plan_later_mine(task.id, opts(me))
    assert lane(me, task) == :later

    assert {:ok, %Task{status: :done, plan: :later}} = Task.complete_mine(task.id, opts(me))
    assert lane(me, task) == :done

    # Reopened, it goes back to the lane it left.
    assert {:ok, %Task{status: :open}} = Task.reopen_mine(task.id, opts(me))
    assert lane(me, task) == :later

    assert {:ok, %Task{status: :cancelled}} = Task.drop_mine(task.id, opts(me))
    assert lane(me, task) == :dropped
  end

  test "a move from the wrong status is refused by the update", %{me: me} do
    task = capture!(me, "Book the venue")

    assert {:error, %Ash.Error.Invalid{}} = Task.reopen_mine(task.id, opts(me))

    {:ok, _} = Task.complete_mine(task.id, opts(me))
    assert {:error, %Ash.Error.Invalid{}} = Task.complete_mine(task.id, opts(me))
    assert {:error, %Ash.Error.Invalid{}} = Task.plan_today_mine(task.id, opts(me))
    assert {:error, %Ash.Error.Invalid{}} = Task.drop_mine(task.id, opts(me))
  end

  test "another member's task is not found by any move, and is not on their list", %{
    me: me,
    other: other
  } do
    mine = capture!(me, "Renew the passport")

    for move <- [:complete_mine, :plan_today_mine, :plan_later_mine, :drop_mine, :reopen_mine] do
      assert {:error, error} = apply(Task, move, [mine.id, opts(other)]), inspect(move)
      assert Exception.message(error) =~ "not found" or match?(%Ash.Error.Invalid{}, error)
    end

    assert {:ok, []} = Task.mine(opts(other))
    assert {:ok, []} = Task.due_today(opts(other))

    reloaded = Ash.get!(Task, mine.id, tenant: me.tenant, authorize?: false)
    assert reloaded.status == :open
    assert reloaded.plan == :inbox
  end

  test "due_today is today's list and anything due by tonight, overdue included", %{me: me} do
    {_from, end_of_today} = LocalTime.days(LocalTime.today(), 1)

    planned = capture!(me, "Planned for today")
    {:ok, _} = Task.plan_today_mine(planned.id, opts(me))

    overdue = capture!(me, "Overdue", %{due_at: DateTime.add(DateTime.utc_now(), -2, :day)})
    tonight = capture!(me, "Due tonight", %{due_at: DateTime.add(end_of_today, -60, :second)})
    _tomorrow = capture!(me, "Due tomorrow", %{due_at: DateTime.add(end_of_today, 3600, :second)})
    _unsorted = capture!(me, "Unsorted, undated")

    done =
      capture!(me, "Already done, due yesterday", %{due_at: DateTime.add(end_of_today, -1, :day)})

    {:ok, _} = Task.complete_mine(done.id, opts(me))

    {:ok, today} = Task.due_today(opts(me))
    assert Enum.map(today, & &1.id) == [overdue.id, tonight.id, planned.id]
  end

  describe "estimate and schedule (planning moves)" do
    @start ~U[2026-11-09 09:00:00.000000Z]
    @finish ~U[2026-11-09 10:30:00.000000Z]

    test "set_estimate_mine records a positive estimate", %{me: me} do
      task = capture!(me, "Draft the review")
      assert task.estimated_minutes == nil

      assert {:ok, %Task{estimated_minutes: 90}} = Task.set_estimate_mine(task.id, 90, opts(me))
    end

    test "an estimate must be positive", %{me: me} do
      task = capture!(me, "Draft the review")

      for bad <- [0, -5] do
        assert {:error, %Ash.Error.Invalid{}} = Task.set_estimate_mine(task.id, bad, opts(me))
      end

      assert Ash.get!(Task, task.id, tenant: me.tenant, authorize?: false).estimated_minutes ==
               nil
    end

    test "schedule_mine places the task and unschedule_mine clears it", %{me: me} do
      task = capture!(me, "Draft the review")

      assert {:ok, %Task{scheduled_start_at: @start, scheduled_end_at: @finish}} =
               Task.schedule_mine(task.id, @start, @finish, opts(me))

      assert {:ok, %Task{scheduled_start_at: nil, scheduled_end_at: nil}} =
               Task.unschedule_mine(task.id, opts(me))
    end

    test "the end must be after the start", %{me: me} do
      task = capture!(me, "Draft the review")

      for {from, to} <- [{@start, @start}, {@finish, @start}] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Task.schedule_mine(task.id, from, to, opts(me))
      end

      reloaded = Ash.get!(Task, task.id, tenant: me.tenant, authorize?: false)
      assert reloaded.scheduled_start_at == nil
      assert reloaded.scheduled_end_at == nil
    end

    test "another member's task is not found by estimate, schedule or unschedule", %{
      me: me,
      other: other
    } do
      mine = capture!(me, "Renew the passport")

      for result <- [
            Task.set_estimate_mine(mine.id, 30, opts(other)),
            Task.schedule_mine(mine.id, @start, @finish, opts(other)),
            Task.unschedule_mine(mine.id, opts(other))
          ] do
        assert {:error, error} = result
        assert Exception.message(error) =~ "not found" or match?(%Ash.Error.Invalid{}, error)
      end

      reloaded = Ash.get!(Task, mine.id, tenant: me.tenant, authorize?: false)
      assert reloaded.estimated_minutes == nil
      assert reloaded.scheduled_start_at == nil
    end

    test "an existing move still works when arguments are forwarded as update input", %{me: me} do
      task = capture!(me, "Regression guard")

      # `record_id` is stripped before forwarding; `plan_today` accepts nothing.
      assert {:ok, %Task{plan: :today, estimated_minutes: nil}} =
               Task.plan_today_mine(task.id, opts(me))

      {:ok, _} = Task.set_estimate_mine(task.id, 45, opts(me))

      assert {:ok, %Task{status: :done, estimated_minutes: 45}} =
               Task.complete_mine(task.id, opts(me))
    end
  end
end
