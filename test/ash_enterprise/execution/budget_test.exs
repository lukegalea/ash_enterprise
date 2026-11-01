defmodule AshEnterprise.Execution.BudgetTest do
  @moduledoc """
  Invariant 8, bounded execution (ADR 0056): a run's token budget is held before each
  model call and settled after it, under `optimistic_lock(:budget_lock)`. However many
  reservations meet on one run, what they hold never adds up past its limit; a run with
  nothing left waits on its budget and makes no call; extending it resumes it (F8).

  Committed for real, with a real Oban whose queues are paused so each test drains them by
  hand.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Runs
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshAgent.Run.BudgetExhausted
  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Execution.Run.StepScheduler

  setup do
    in_zone!()
    pause_queues!()
    clinic = clinic!()
    published!(clinic)
    %{clinic: clinic}
  end

  # Written past the actions, as a test sets up a run part-way through its budget.
  defp budget!(run, fields) do
    {1, _} =
      Repo.update_all(
        from(r in "exec_agent_runs", where: r.id == type(^run.id, Ecto.UUID)),
        set: fields
      )

    run(run)
  end

  # One holder's reservation of `tokens`: read the run, reserve, and read it again
  # whenever another write won, until it is held or refused.
  defp reserve_until_decided(run, holder, tokens, attempts \\ 100) do
    input = %{run_id: holder, epoch: 1, tokens: tokens}

    case Execution.reserve_agent_run_budget(run(run), input, oban(run.organization_id)) do
      {:ok, _held} ->
        :held

      {:error, %{errors: [%BudgetExhausted{}]}} ->
        :refused

      {:error, %{errors: [%Ash.Error.Changes.StaleRecord{}]}} when attempts > 1 ->
        reserve_until_decided(run, holder, tokens, attempts - 1)
    end
  end

  # The tokens the run's model calls reported, as the ledger recorded them.
  defp ledger_tokens(run) do
    prefix = "run:#{run.id}:"

    ModelCall
    |> Ash.Query.filter(contains(caller, ^prefix))
    |> Ash.read!(authorize?: false)
    |> Enum.map(&((&1.input_tokens || 0) + (&1.output_tokens || 0)))
    |> Enum.sum()
  end

  test "concurrent reservations never add up past the limit", %{clinic: %{nurse: nurse}} do
    check all(
            asks <- StreamData.list_of(StreamData.integer(1..450), min_length: 2, max_length: 10),
            max_runs: 8
          ) do
      {:ok, run} = start(nurse)
      run = budget!(run, budget_limit: 1_000)
      holders = Enum.map(asks, fn _ask -> Ash.UUID.generate() end)

      decided =
        race(length(asks), fn i ->
          reserve_until_decided(run, Enum.at(holders, i), Enum.at(asks, i))
        end)

      held = for {:held, ask} <- Enum.zip(decided, asks), do: ask
      refused = for {:refused, ask} <- Enum.zip(decided, asks), do: ask
      after_race = run(run)

      # What was held is exactly what the row holds, by holder, and within the limit.
      assert after_race.budget_reserved == Enum.sum(held)
      assert after_race.budget_reserved == Enum.sum(Map.values(after_race.budget_holds))
      assert map_size(after_race.budget_holds) == length(held)
      assert after_race.budget_spent + after_race.budget_reserved <= after_race.budget_limit

      # Room only shrank during the race, so every refusal asked for more than is left.
      assert Enum.all?(refused, &(&1 > after_race.budget_limit - after_race.budget_reserved))
    end
  end

  test "concurrent steps of one run hold once and settle what the call used",
       %{clinic: %{nurse: nurse}} do
    script!([{:text, ~s({"recorded": 0})}, {:text, ~s({"recorded": 9})}])
    {:ok, run} = start(nurse)

    outcomes = race(3, fn _ -> step!(run) end)
    assert Enum.count(outcomes, &(&1 == :completed)) == 1
    assert Enum.count(outcomes, &(&1 == :skipped)) == 2

    done = run(run)
    assert %{budget_spent: 48, budget_reserved: 0} = done
    assert done.budget_holds == %{}
    assert ledger_tokens(run) == done.budget_spent
  end

  test "a worker killed during its call leaves its hold, which the next lease releases",
       %{clinic: %{nurse: nurse}} do
    script!([{:exit, :worker_killed}, {:text, ~s({"recorded": 0})}])
    {:ok, run} = start(nurse)

    {pid, ref} = spawn_monitor(fn -> step!(run) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :worker_killed}, 10_000

    died = run(run)
    assert %{status: :running, budget_reserved: 20_000, budget_spent: 0} = died
    assert died.budget_holds == %{"#{run.id}:#{died.lease_epoch}" => 20_000}

    # The lease runs out; the run is queued again and its next step takes its own hold,
    # releasing the dead worker's.
    elapse_lease!(run)
    assert %{status: :queued} = Execution.recover_agent_run!(died, oban(run.organization_id))
    assert step!(run) == :completed

    done = run(run)
    assert %{budget_spent: 48, budget_reserved: 0} = done
    assert done.budget_holds == %{}
    assert [{_killed, _}, {_repeated, :ok}] = model_calls(run)
  end

  test "a run that exhausts its budget waits on it with no model call; extending it resumes (F8)",
       %{clinic: %{nurse: nurse, admin: admin, tenant: tenant}} do
    n = System.unique_integer([:positive])

    script!([
      {:tools, [record_call("call_a", "SYNTHETIC: book the scan #{n}")]},
      {:text, ~s({"recorded": 1})}
    ])

    {:ok, run} = start(nurse)
    budget!(run, budget_limit: 48)

    # The first call spends the whole budget and asks for a tool.
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)
    assert %{status: :waiting, blocked_on: :tools, budget_spent: 48} = run(run)

    # The tool finishes and wakes the run; its claim finds nothing left.
    [call] = invocations(run)
    assert {:ok, :succeeded} = Executor.execute(Invocation, call.id, oban(tenant))
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)

    waiting = run(run)

    assert %{status: :waiting, blocked_on: :budget, error_code: "token_budget"} = waiting
    assert length(model_calls(run)) == 1

    # Nothing wakes it but an extension: not a sweep, and not the nurse who started it.
    Oban.insert!(StepScheduler.new(%{}))
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    assert run(run).status == :waiting
    assert step_jobs(run) == []

    assert {:error, %Ash.Error.Forbidden{}} =
             Execution.extend_agent_run_budget(waiting, 1_000, actor: nurse.actor, tenant: tenant)

    # An administrator extends it: the run is queued again with its step enqueued, and
    # completes.
    assert {:ok, %{status: :queued, blocked_on: nil, budget_limit: 1_048}} =
             Execution.extend_agent_run_budget(waiting, 1_000, actor: admin.actor, tenant: tenant)

    assert step_jobs(run) != []
    assert %{failure: 0} = Oban.drain_queue(queue: :agent_runs)

    done = run(run)
    assert %{status: :completed, budget_spent: 96, budget_reserved: 0} = done
    assert ledger_tokens(run) == done.budget_spent
  end
end
