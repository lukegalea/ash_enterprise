defmodule AshEnterprise.AgentSpike.S4FencedAuditedUpdateTest do
  @moduledoc """
  Spike S4: fencing on an audited resource.

  **Reading tested.** The audit wrapper refuses atomic updates, so lease
  fencing and budget checks must be built from the two primitives that
  survive it: Ash's built-in `optimistic_lock` and a filter on the update.
  The wrapper writes its audit event *before* it runs the data layer's
  `UPDATE … WHERE`; the reading is that a stale write (the filter matches no
  row) fails with `StaleRecord` and rolls the pre-written event back with
  it, so the log never records a write that did not happen.

  **Result: holds.** On `AshEnterprise.Canonical.Task` (audited, real
  table): a stale `optimistic_lock` write and a filtered write whose filter
  no longer matches both fail with `StaleRecord`, leave the row as the
  winner wrote it, and leave no audit event behind. The winning write
  increments `version_number` once and records one event. The last test pins
  the constraint itself: an atomic update on an audited row is refused and
  writes nothing.

  Fallback had this failed (plan Risk 2): a non-audited lease row beside the
  audited one.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  require Ash.Expr
  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.SystemActor

  setup do
    ctx = tenant!()

    task =
      Task.capture!("Send the referral letter to the cardiology clinic", %{},
        actor: ctx.actor,
        tenant: ctx.tenant
      )

    %{ctx: ctx, task: task, opts: [actor: SystemActor.oban(), tenant: ctx.tenant]}
  end

  defp events(task) do
    id = task.id

    EventLog
    |> Ash.Query.filter(record_id == ^id)
    |> Ash.read!(authorize?: false)
  end

  # Ash's built-in optimistic lock, applied to the changeset as an action's
  # `change optimistic_lock(:version_number)` would apply it.
  defp locked(changeset) do
    Ash.Resource.Change.OptimisticLock.change(
      changeset,
      [attribute: :version_number],
      %Ash.Resource.Change.Context{}
    )
  end

  defp stale?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

  defp stale?(_), do: false

  test "a stale optimistic-lock write fails and its pre-written event is rolled back",
       %{task: task, opts: opts} do
    copy_a = Ash.get!(Task, task.id, opts)
    copy_b = Ash.get!(Task, task.id, opts)
    assert copy_a.version_number == copy_b.version_number
    before = length(events(task))

    assert {:ok, won} =
             copy_a
             |> Ash.Changeset.for_update(:plan_today, %{}, opts)
             |> locked()
             |> Ash.update()

    assert won.version_number == copy_a.version_number + 1
    assert length(events(task)) == before + 1

    assert {:error, error} =
             copy_b
             |> Ash.Changeset.for_update(:plan_later, %{}, opts)
             |> locked()
             |> Ash.update()

    assert stale?(error)

    # The loser's event was written before its UPDATE and went with the rollback.
    assert length(events(task)) == before + 1
    current = Ash.get!(Task, task.id, opts)
    assert current.plan == :today
    assert current.version_number == won.version_number
  end

  test "a filtered write whose filter no longer matches fails and leaves no event",
       %{task: task, opts: opts} do
    stale_copy = Ash.get!(Task, task.id, opts)

    task |> Ash.Changeset.for_update(:complete, %{}, opts) |> Ash.update!()
    before = length(events(task))

    # A fence in the shape the plan uses: "only while still open".
    assert {:error, error} =
             stale_copy
             |> Ash.Changeset.for_update(:plan_later, %{}, opts)
             |> Ash.Changeset.filter(Ash.Expr.expr(status == :open))
             |> Ash.update()

    assert stale?(error)
    assert length(events(task)) == before
    assert Ash.get!(Task, task.id, opts).status == :done
  end

  test "an atomic update on an audited row is refused and writes nothing",
       %{task: task, opts: opts} do
    before = length(events(task))

    result =
      try do
        task
        |> Ash.Changeset.for_update(:plan_today, %{}, opts)
        |> Ash.Changeset.atomic_update(:version_number, Ash.Expr.expr(version_number + 1))
        |> Ash.update()
      rescue
        error -> {:error, error}
      end

    assert {:error, error} = result
    assert Exception.message(error) =~ "atomic"
    assert length(events(task)) == before
    assert Ash.get!(Task, task.id, opts).version_number == task.version_number
  end
end
