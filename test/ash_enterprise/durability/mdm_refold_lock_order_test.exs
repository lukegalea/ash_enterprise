defmodule AshEnterprise.Durability.MdmRefoldLockOrderTest do
  @moduledoc """
  `AshEnterprise.Mdm.Refold`'s locks against other connections: the tenant's
  audit lock first, then goldens. Every interleaving here is forced by holding
  the audit lock in the test and waiting until Postgres reports the others
  blocked, so neither test depends on timing.

  The sandbox cannot show this: it has one connection, and a lock taken twice
  on it never waits.
  """

  use AshEnterprise.DurabilityCase, async: false

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.Refold
  alias AshEnterprise.Platform.Seeder

  setup do
    unique = System.unique_integer([:positive])

    %{organization: organization, user: user} =
      Seeder.seed_tenant(name: "Lock order #{unique}", unique_name: "lock-order-#{unique}")

    %{tenant: organization.id, user: user}
  end

  test "an audited write holding the tenant's lock and a refold do not deadlock", ctx do
    golden = person!(ctx, "Golden")
    test_pid = self()

    # Holds the audit lock by being an audited write, as the batch and steward
    # paths do, and asks for the golden's lock only once the refold is waiting.
    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          person!(ctx, "Audited write")
          send(test_pid, :holding_audit_lock)

          receive do
            :refold -> Refold.refold!(ctx.tenant, golden.id)
          end
        end)
      end)

    assert_receive :holding_audit_lock, 10_000

    refolder = Task.async(fn -> Refold.refold!(ctx.tenant, golden.id) end)
    await_advisory_waiters(1)

    send(writer.pid, :refold)

    assert {:ok, %{golden: %{id: id}}} = Task.await(writer, 20_000)
    assert id == golden.id
    assert %{golden: %{id: ^id}} = Task.await(refolder, 20_000)
  end

  test "two goldens merging into each other: one merge stands and there is no cycle", ctx do
    first = person!(ctx, "First")
    second = person!(ctx, "Second")
    test_pid = self()

    # Both merges read their records now, before either can commit.
    merges = [merge_changeset(ctx, first, second), merge_changeset(ctx, second, first)]

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          person!(ctx, "Audited write")
          send(test_pid, :holding_audit_lock)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :holding_audit_lock, 10_000

    tasks = Enum.map(merges, fn changeset -> Task.async(fn -> merge(changeset) end) end)
    await_advisory_waiters(2)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 20_000)

    results = Task.await_many(tasks, 20_000)

    assert [{:ok, %Person{}}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, %Ash.Error.Invalid{}}] = Enum.filter(results, &match?({:error, _}, &1))

    assert [%{merged: false, master_id: nil}, %{merged: true, master_id: master}] =
             [first, second]
             |> Enum.map(&Ash.reload!(&1, tenant: ctx.tenant, authorize?: false))
             |> Enum.sort_by(& &1.merged)

    assert master in [first.id, second.id]
  end

  defp person!(ctx, name) do
    Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: name,
      email: "p-#{System.unique_integer([:positive])}@lock-order.synthetic.test",
      owner_id: ctx.user.id,
      owning_business_unit_id: ctx.user.owning_business_unit_id
    })
    |> Ash.create!(tenant: ctx.tenant, authorize?: false)
  end

  defp merge_changeset(ctx, loser, survivor) do
    Ash.Changeset.for_update(loser, :mdm_merge_into, %{survivor_id: survivor.id},
      tenant: ctx.tenant,
      authorize?: false
    )
  end

  defp merge(changeset), do: Ash.update(changeset, tenant: changeset.tenant, authorize?: false)

  # Polled because Postgres has no notification for a backend starting to wait.
  defp await_advisory_waiters(count, attempts \\ 500) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted " <>
          "AND database = (SELECT oid FROM pg_database WHERE datname = current_database())"
      )

    cond do
      waiting >= count ->
        :ok

      attempts == 0 ->
        flunk("#{waiting} of #{count} connections were waiting on an advisory lock")

      true ->
        poll_again(count, attempts)
    end
  end

  defp poll_again(count, attempts) do
    Process.sleep(20)
    await_advisory_waiters(count, attempts - 1)
  end
end
