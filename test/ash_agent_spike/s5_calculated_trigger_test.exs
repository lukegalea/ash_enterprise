defmodule AshEnterprise.AgentSpike.S5CalculatedTriggerTest do
  @moduledoc """
  Spike S5: a trigger whose `where` is a calculation, on a resource built on
  `AshEnterprise.Platform.Resource` with its default policies, taking its
  tenant from the row and running a generic action.

  **Reading tested.** The durable runtime's triggers can (a) select rows by a
  calculated `where` that Postgres evaluates, under the inherited policies,
  as the `:oban` system actor; (b) run each job in the row's own tenant with
  `use_tenant_from_record? true` while the scheduler reads across tenants;
  (c) run a generic action that holds no transaction, so it may call out;
  and (d) leave one winner when the same row is stepped twice.

  **Result: holds, with one correction.** (a)–(d) pass. The correction is
  recorded in the last test: a trigger whose action is a *generic* action
  does **not** re-read the row against `where` before running (ash_oban only
  does that for update and destroy triggers), so `TriggerNoLongerApplies`
  never fires for it. The "worker re-checks `where`" half of reliable
  wake-up must therefore live in the action: its first write is a filtered
  claim, and a claim that matches nothing ends the job quietly.

  Also found: a trigger declared with `scheduler_cron false` has no scheduler
  at all, so nothing sweeps it (`AshOban.Test.schedule_and_run_triggers/2`
  skips it too). The plan's triggers keep a sweep, so they declare a cron.

  The rows live in an existing table through `AshEnterprise.AgentSpike.Subject`
  (no schema is added); see that module for why.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  require Ash.Query

  alias AshEnterprise.AgentSpike.Subject
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.SystemActor

  defp row!(ctx, title, plan) do
    task = Task.capture!(title, %{}, actor: ctx.actor, tenant: ctx.tenant)
    oban = [actor: SystemActor.oban(), tenant: ctx.tenant]
    row = Ash.get!(Subject, task.id, oban)

    row
    |> Ash.Changeset.for_update(:set_plan, %{plan: plan}, oban)
    |> Ash.update!()
  end

  defp drain_steps do
    flush_steps()
    result = AshOban.Test.schedule_and_run_triggers({Subject, :step})
    {result, collect_steps([])}
  end

  defp flush_steps do
    receive do
      {:agent_spike_step, _} -> flush_steps()
    after
      0 -> :ok
    end
  end

  defp collect_steps(acc) do
    receive do
      {:agent_spike_step, seen} -> collect_steps([seen | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  setup do
    clinic_a = tenant!()
    clinic_b = tenant!()
    %{a: clinic_a, b: clinic_b}
  end

  test "the calculated where selects only rows with a step, in every tenant", %{a: a, b: b} do
    due_a = row!(a, "Call the lab about the morning panel", :today)
    due_b = row!(b, "Confirm tomorrow's first appointment", :today)
    idle = row!(a, "Restock the waiting room leaflets", :later)

    oban = [actor: SystemActor.oban()]

    selected =
      Subject
      |> Ash.Query.filter(needs_step)
      |> Ash.Query.filter(id in ^[due_a.id, due_b.id, idle.id])
      |> Ash.read!(oban)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    # The scheduler's query: no tenant (the attribute strategy is global),
    # the `:oban` actor through the inherited policies, the calculation in SQL.
    assert selected == Enum.sort([due_a.id, due_b.id])
  end

  test "each job runs in its row's tenant, as the oban actor, outside a transaction",
       %{a: a, b: b} do
    due_a = row!(a, "Call the lab about the morning panel", :today)
    due_b = row!(b, "Confirm tomorrow's first appointment", :today)

    {result, seen} = drain_steps()
    assert %{success: success, failure: 0} = result
    assert success >= 2

    by_id = Map.new(seen, &{&1.id, &1})
    assert by_id[due_a.id].tenant == a.tenant
    assert by_id[due_b.id].tenant == b.tenant
    assert %SystemActor{name: :oban} = by_id[due_a.id].actor
    refute by_id[due_a.id].in_transaction?

    oban = [actor: SystemActor.oban()]
    assert Ash.get!(Subject, due_a.id, Keyword.put(oban, :tenant, a.tenant)).plan == :later
    assert Ash.get!(Subject, due_b.id, Keyword.put(oban, :tenant, b.tenant)).plan == :later

    # Stepped rows no longer match the calculated where: nothing more runs.
    {_result, again} = drain_steps()
    refute Enum.any?(again, &(&1.id in [due_a.id, due_b.id]))
  end

  test "a generic trigger action is not re-checked against where: the claim decides",
       %{a: a} do
    due = row!(a, "Call the lab about the morning panel", :today)
    oban = [actor: SystemActor.oban(), tenant: a.tenant]

    # The scheduler saw the row; another worker claims it before this job runs.
    job = AshOban.build_trigger(due, :step, actor: SystemActor.oban())

    Subject
    |> Ash.get!(due.id, oban)
    |> Ash.Changeset.for_update(:claim_step, %{}, oban)
    |> Ash.update!()

    flush_steps()
    assert :ok = Subject.StepWorker.perform(%Oban.Job{args: stringify(job.changes.args)})

    # The worker ran the action although the row no longer matches `where`
    # (an update trigger would have raised TriggerNoLongerApplies first); the
    # filtered claim inside the action is what made the second run a no-op.
    assert [%{id: id}] = collect_steps([])
    assert id == due.id
    assert Ash.get!(Subject, due.id, oban).plan == :later
  end

  defp stringify(args), do: args |> Jason.encode!() |> Jason.decode!()
end
