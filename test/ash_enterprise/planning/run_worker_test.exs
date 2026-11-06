defmodule AshEnterprise.Planning.RunWorkerTest do
  @moduledoc """
  The Oban worker drives a run from request to recorded outcome. Jobs are performed directly
  (`Oban` is `testing: :manual`), against the Fake backend; the check pipeline is a stub so the
  worker's own steps are what is under test. Not async: the heavy-slot registry, the model
  directory and the `:planning` config are node-global.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Planning.TestKit

  alias AshEnterprise.Planning
  alias AshPlanning.Backend.Fake
  alias AshEnterprise.Planning.LeaseSweeper
  alias AshEnterprise.Planning.Registry, as: PlanningRegistry
  alias AshEnterprise.Planning.RunWorker
  alias AshEnterprise.Planning.SnapshotBuilder

  defmodule CheckStub do
    @moduledoc false
    def process(run) do
      send(Application.fetch_env!(:ash_enterprise, :planning_test_pid), {:checked, run.id})
      :ok
    end
  end

  setup do
    original = Application.get_env(:ash_enterprise, :planning, [])
    original_dir = Application.get_env(:ash_enterprise, :planning_model_dir)

    Application.put_env(
      :ash_enterprise,
      :planning,
      Keyword.merge(original,
        backends: %{"fake" => Fake},
        check_pipeline: CheckStub,
        poll_ms: 50,
        lease_ms: 5_000
      )
    )

    Application.put_env(:ash_enterprise, :planning_test_pid, self())

    on_exit(fn ->
      Application.put_env(:ash_enterprise, :planning, original)
      Application.put_env(:ash_enterprise, :planning_model_dir, original_dir)
      Application.delete_env(:ash_enterprise, :planning_test_pid)
    end)

    ensure_runtime!()
    publish_requirements!()
    w = world!()
    task!(w, "write", 60)
    %{w: w}
  end

  # The application supervisor owns these once wired; start them for the test only when absent.
  defp ensure_runtime! do
    unless Process.whereis(AshEnterprise.Planning.Registry),
      do: start_supervised!(AshEnterprise.Planning.Registry)

    unless Process.whereis(AshEnterprise.Planning.SessionSupervisor),
      do: start_supervised!(AshEnterprise.Planning.SessionSupervisor)
  end

  defp job(run), do: %Oban.Job{args: %{"run_id" => run.id}}
  defp reload(run), do: Planning.get_planning_run!(run.id, authorize?: false)

  defp hold_heavy_slot do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = PlanningRegistry.claim_heavy_slot(Ecto.UUID.generate(), 1)
        send(parent, :slot_held)
        receive do: (:release -> :ok)
      end)

    assert_receive :slot_held
    pid
  end

  defp release_heavy_slot(pid) do
    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    wait_until(fn -> PlanningRegistry.heavy_slots_in_use() == 0 end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  test "pending -> prepared -> solved: one perform prepares, solves, records and checks", %{w: w} do
    assert w.run.preparation_status == :pending
    assert :ok = RunWorker.perform(job(w.run))

    run = reload(w.run)
    assert run.preparation_status == :prepared
    assert run.snapshot_digest =~ ~r/\A[0-9a-f]{64}\z/
    assert run.solve_status == :optimal
    assert run.complete?
    assert run.lease_epoch == 1
    assert is_nil(run.lease_expires_at)
    assert_received {:checked, run_id}
    assert run_id == run.id
  end

  test "a needs_input preparation finishes without a solve", %{w: w} do
    # An unestimated task makes the plan unsolvable: name it, do not guess.
    task!(w, "no estimate")
    assert :ok = RunWorker.perform(job(w.run))
    run = reload(w.run)
    assert run.preparation_status == :needs_input
    assert is_nil(run.solve_status)
    assert run.lease_epoch == 0
    refute_received {:checked, _}
  end

  test "heavy_solve_busy snoozes without recording; the retry solves once the slot frees", %{w: w} do
    {:ok, prepared} = SnapshotBuilder.prepare(w.run)
    holder = hold_heavy_slot()

    assert {:snooze, 15} = RunWorker.perform(job(prepared))
    busy = reload(w.run)
    assert is_nil(busy.solve_status)
    assert busy.lease_epoch == 0
    assert busy.preparation_status == :prepared

    release_heavy_slot(holder)
    assert :ok = RunWorker.perform(job(prepared))
    assert reload(w.run).solve_status == :optimal
  end

  test "enqueueing the same run twice yields one job" do
    run_id = Ecto.UUID.generate()
    assert {:ok, first} = RunWorker.enqueue(run_id)
    assert {:ok, second} = RunWorker.enqueue(run_id)
    assert second.conflict?
    assert second.id == first.id
    assert first.args == %{"run_id" => run_id}

    import Ecto.Query

    jobs =
      Oban.Job
      |> where([j], j.worker == "AshEnterprise.Planning.RunWorker")
      |> where([j], fragment("?->>'run_id'", j.args) == ^run_id)
      |> then(&Oban.Repo.all(Oban.config(), &1))

    assert [_one] = jobs
  end

  test "re-performing after an outcome is a no-op that never starts a second solve", %{w: w} do
    assert :ok = RunWorker.perform(job(w.run))
    before = reload(w.run)
    assert before.solve_status == :optimal

    assert :ok = RunWorker.perform(job(w.run))
    assert :ok = RunWorker.perform(job(w.run))

    after_run = reload(w.run)
    assert after_run.lease_epoch == before.lease_epoch
    assert after_run.solve_status == before.solve_status
    assert after_run.updated_at == before.updated_at
  end

  test "a job for an unknown run is cancelled, not retried" do
    assert {:cancel, _} = RunWorker.perform(job(%{id: Ecto.UUID.generate()}))
    assert {:cancel, _} = RunWorker.perform(%Oban.Job{args: %{}})
  end

  test "a cancel on record before the start is recorded :cancelled and nothing is solved", %{w: w} do
    Planning.request_planning_run_cancel!(w.run, %{reason: :requested}, w.oban)

    assert :ok = RunWorker.perform(job(w.run))
    run = reload(w.run)
    assert run.solve_status == :cancelled
    assert run.lease_epoch == 0
    refute run.complete?
    refute_received {:checked, _}
  end

  describe "lease expiry" do
    defp started_with_lease(w, lease_for) do
      {:ok, prepared} = SnapshotBuilder.prepare(w.run)

      Planning.start_planning_run!(
        prepared,
        %{backend: %{"backend" => "fake"}, session_pid: "gone", lease_for: lease_for},
        w.oban
      )
    end

    test "an expired lease with no session ends the run :unknown / :lease_lost", %{w: w} do
      started_with_lease(w, 1)
      Process.sleep(10)

      assert :ok = RunWorker.perform(job(w.run))
      run = reload(w.run)
      assert run.solve_status == :unknown
      assert run.outcome_reason == :lease_lost
      refute run.complete?
      assert run.optimality == :none
    end

    test "a live lease with no local session snoozes past the lapse", %{w: w} do
      started_with_lease(w, 30_000)
      assert {:snooze, seconds} = RunWorker.perform(job(w.run))
      assert seconds >= 2
      assert is_nil(reload(w.run).solve_status)
    end

    test "a recorded cancel turns the expiry into :cancelled", %{w: w} do
      started_with_lease(w, 1)
      Planning.request_planning_run_cancel!(reload(w.run), %{reason: :requested}, w.oban)
      Process.sleep(10)

      assert :ok = RunWorker.perform(job(w.run))
      assert reload(w.run).solve_status == :cancelled
    end

    test "the sweeper ends expired runs once; a second sweep is a no-op", %{w: w} do
      started_with_lease(w, 1)
      Process.sleep(10)

      assert :ok = LeaseSweeper.perform(%Oban.Job{})
      swept = reload(w.run)
      assert {swept.solve_status, swept.outcome_reason} == {:unknown, :lease_lost}

      assert :ok = LeaseSweeper.perform(%Oban.Job{})
      assert reload(w.run).updated_at == swept.updated_at
    end

    test "expire/1 on a run that already has an outcome is refused, never overwriting", %{w: w} do
      started_with_lease(w, 1)
      Process.sleep(10)
      stale = reload(w.run)
      assert :ok = LeaseSweeper.expire(stale)
      assert {:error, _} = LeaseSweeper.expire(stale)
      assert reload(w.run).solve_status == :unknown
    end
  end
end
