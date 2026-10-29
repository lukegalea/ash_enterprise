defmodule AshEnterprise.Execution.LeaseFencingTest do
  @moduledoc """
  Invariant 3, lease fencing (ADR 0055): a worker whose lease was taken over cannot
  complete, and the effect it made in the meantime rolls back with its refused
  completion.

  Every claim takes the next lease epoch under an optimistic lock; every completion is
  filtered on the epoch its worker claimed with, in the same transaction as the target's
  effect. The tests drive two workers by hand, with the `:execution` queue paused so no
  real job interferes, and leases that expire at once so the second worker may always
  take the row over.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Durable

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Execution

  setup do
    pause_execution!()
    clinic!()
  end

  defp requested!(nurse, title) do
    key = "fence:#{System.unique_integer([:positive])}"
    {:ok, row} = invoke(nurse, record_target(), %{"title" => title}, key)
    row
  end

  defp current(row, tenant), do: Execution.get_invocation!(row.id, oban(tenant))

  defp events(row) do
    id = row.id

    EventLog
    |> Ash.Query.filter(record_id == ^id)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&to_string(&1.action))
  end

  test "A claims and stalls, its lease expires, B takes over and succeeds; A is refused and its effect rolled back",
       %{nurse: nurse, tenant: tenant} do
    title = "Send the referral letter #{System.unique_integer([:positive])}"
    row = requested!(nurse, title)

    # A claims, and its lease runs out before it does anything.
    {:ok, a} = Executor.claim(row, oban(tenant), lease_for: 0)

    # B finds the lease expired, takes the next epoch and finishes the work.
    {:ok, b} = Executor.claim(current(row, tenant), oban(tenant))
    assert b.lease_epoch == a.lease_epoch + 1
    assert {:ok, :succeeded} = Executor.run_claimed(b, oban(tenant))
    assert effects(tenant, title) == 1

    # A wakes up: it runs the target, and its completion under the old epoch is refused
    # in the same transaction, so the second note never commits.
    assert {:ok, :superseded} = Executor.run_claimed(a, oban(tenant))
    assert effects(tenant, title) == 1

    done = current(row, tenant)
    assert {done.status, done.lease_epoch} == {:succeeded, b.lease_epoch}

    # The log records B's completion and nothing of A's.
    assert events(row) == ["request", "claim", "claim", "succeed"]
  end

  test "a lease that has not expired is not taken over", %{nurse: nurse, tenant: tenant} do
    row = requested!(nurse, "Order gloves #{System.unique_integer([:positive])}")
    {:ok, _a} = Executor.claim(row, oban(tenant))
    assert {:error, :not_claimable} = Executor.claim(current(row, tenant), oban(tenant))
  end

  test "of two claims raced from one reading, exactly one wins", %{nurse: nurse, tenant: tenant} do
    row = requested!(nurse, "Order masks #{System.unique_integer([:positive])}")

    results = race(8, fn _ -> Executor.claim(row, oban(tenant), lease_for: 0) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_claimable})) == 7
    assert current(row, tenant).lease_epoch == 1
  end

  property "in every interleaving of two workers, exactly one effect commits and it is the holder's",
           %{nurse: nurse, tenant: tenant} do
    scripts = %{a: [:claim, :complete], b: [:claim, :complete]}

    check all(order <- Interleavings.interleaving(scripts), max_runs: 30) do
      title = "Fenced note #{System.unique_integer([:positive])}"
      row = requested!(nurse, title)

      Interleavings.run(
        order,
        %{row: row, held: %{}, won: nil},
        fn step, state -> step(step, state, tenant) end,
        fn state -> invariants(state, tenant, title) end
      )

      # Whatever the order, the work is done once.
      done = current(row, tenant)
      assert done.status == :succeeded
      assert effects(tenant, title) == 1
    end
  end

  defp step({worker, :claim}, state, tenant) do
    case Executor.claim(current(state.row, tenant), oban(tenant), lease_for: 0) do
      {:ok, claimed} -> put_in(state, [:held, worker], claimed)
      {:error, :not_claimable} -> state
    end
  end

  defp step({worker, :complete}, state, tenant) do
    case Map.fetch(state.held, worker) do
      {:ok, claimed} ->
        case Executor.run_claimed(claimed, oban(tenant)) do
          {:ok, :succeeded} -> %{state | won: claimed.lease_epoch}
          {:ok, :superseded} -> state
        end

      :error ->
        state
    end
  end

  defp invariants(state, tenant, title) do
    row = current(state.row, tenant)
    count = effects(tenant, title)

    assert count <= 1

    if row.status == :succeeded do
      assert count == 1
      assert row.lease_epoch == state.won
    else
      assert count == 0
      assert is_nil(state.won)
    end
  end
end
