defmodule AshEnterprise.Planning.SolverSessionTest do
  @moduledoc """
  One session per run: refusals before anything is spawned, the heavy-slot and registry
  guards, the cancel ladder, outcomes recorded from a scripted backend and lease renewal under
  poll ticks. A scripted backend wraps `Backend.Fake`; no minizinc is involved. Not async: the
  heavy-slot registry, the model directory and the `:planning` config are node-global.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Planning.TestKit

  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.Registry, as: PlanningRegistry
  alias AshEnterprise.Planning.SessionSupervisor
  alias AshEnterprise.Planning.SnapshotBuilder
  alias AshEnterprise.Planning.SolverSession
  alias AshPlanning.Backend.Fake

  defmodule Scripted do
    @moduledoc false
    # Fake, with the script taken from `:planning_test_script` (merged over the problem data)
    # and, when `:planning_test_gate` names a pid, a solve that holds until released or
    # cancelled.
    @behaviour AshPlanning.Backend

    @impl true
    defdelegate capabilities, to: Fake

    @impl true
    def start(problem, opts) do
      script = Application.get_env(:ash_enterprise, :planning_test_script, %{})
      data = problem.data |> Map.new() |> Map.merge(script)
      Fake.start(%{problem | data: data}, opts)
    end

    @impl true
    def await(ref, timeout) do
      case Application.get_env(:ash_enterprise, :planning_test_gate) do
        nil ->
          :ok

        gate ->
          send(gate, {:awaiting, self()})
          hold(ref)
      end

      Fake.await(ref, timeout)
    end

    defp hold(ref) do
      receive do
        :release -> :ok
      after
        20 ->
          if Fake.status(ref) == {:error, :not_running} or cancelled?(ref),
            do: :ok,
            else: hold(ref)
      end
    end

    defp cancelled?(%{agent: agent}) do
      Agent.get(agent, & &1.cancelled?)
    catch
      :exit, _ -> true
    end

    @impl true
    defdelegate status(ref), to: Fake

    # With `:planning_test_cancel_gate` naming a pid, a cancel that never returns.
    @impl true
    def cancel(ref) do
      case Application.get_env(:ash_enterprise, :planning_test_cancel_gate) do
        nil ->
          Fake.cancel(ref)

        gate ->
          send(gate, {:cancelling, self()})
          Process.sleep(:infinity)
      end
    end
  end

  setup do
    original = Application.get_env(:ash_enterprise, :planning, [])
    original_dir = Application.get_env(:ash_enterprise, :planning_model_dir)

    Application.put_env(
      :ash_enterprise,
      :planning,
      Keyword.merge(original,
        backends: %{"fake" => Scripted},
        poll_ms: 40,
        lease_ms: 900,
        max_heavy_sessions: 1
      )
    )

    on_exit(fn ->
      Application.put_env(:ash_enterprise, :planning, original)
      Application.put_env(:ash_enterprise, :planning_model_dir, original_dir)
      Application.delete_env(:ash_enterprise, :planning_test_script)
      Application.delete_env(:ash_enterprise, :planning_test_gate)
      Application.delete_env(:ash_enterprise, :planning_test_cancel_gate)
    end)

    ensure_runtime!()
    publish_requirements!()
    w = world!()
    task!(w, "write", 60)
    {:ok, prepared} = SnapshotBuilder.prepare(w.run)
    %{w: w, run: prepared}
  end

  # The application supervisor owns these once wired; start them for the test only when absent.
  defp ensure_runtime! do
    unless Process.whereis(AshEnterprise.Planning.Registry),
      do: start_supervised!(AshEnterprise.Planning.Registry)

    unless Process.whereis(AshEnterprise.Planning.SessionSupervisor),
      do: start_supervised!(AshEnterprise.Planning.SessionSupervisor)
  end

  defp gate!, do: Application.put_env(:ash_enterprise, :planning_test_gate, self())
  defp script!(script), do: Application.put_env(:ash_enterprise, :planning_test_script, script)
  defp reload(run), do: Planning.get_planning_run!(run.id, authorize?: false)

  defp await_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    reason
  end

  defp start_and_finish(run) do
    assert {:ok, pid} = SolverSession.start_run(run)
    assert :normal = await_down(pid)
    reload(run)
  end

  describe "refusals" do
    test "model_missing when a pinned file's sha256 no longer matches", %{w: w, run: run} do
      dir = Application.fetch_env!(:ash_enterprise, :planning_model_dir)
      key = w.mv.key
      File.write!(Path.join([dir, key, key <> ".mzn"]), "% tampered\n")

      assert {:error, :model_missing} = SolverSession.start_run(run)
      assert reload(run).lease_epoch == 0
      assert SessionSupervisor.active_count() == 0
    end

    test "model_missing when the model directory is unset", %{run: run} do
      Application.delete_env(:ash_enterprise, :planning_model_dir)
      assert {:error, :model_missing} = SolverSession.start_run(run)
    end

    test "resource_governor_unavailable when the governor binary cannot be found", %{run: run} do
      original = Application.get_env(:ash_enterprise, :planning)

      Application.put_env(
        :ash_enterprise,
        :planning,
        Keyword.put(original, :prlimit, "no-such-governor-binary")
      )

      assert {:error, :resource_governor_unavailable} = SolverSession.start_run(run)
      assert reload(run).lease_epoch == 0
    end

    test "unknown_backend when the profile's backend is not in the allow-list", %{run: run} do
      original = Application.get_env(:ash_enterprise, :planning)
      Application.put_env(:ash_enterprise, :planning, Keyword.put(original, :backends, %{}))
      assert {:error, :unknown_backend} = SolverSession.start_run(run)
    end

    test "heavy_solve_busy when every slot is held; nothing is started", %{run: run} do
      parent = self()

      holder =
        spawn(fn ->
          {:ok, _} = PlanningRegistry.claim_heavy_slot(Ecto.UUID.generate(), 1)
          send(parent, :held)
          receive do: (:release -> :ok)
        end)

      on_exit(fn -> send(holder, :release) end)
      assert_receive :held

      assert {:error, :heavy_solve_busy} = SolverSession.start_run(run)
      assert SessionSupervisor.active_count() == 0
      assert reload(run).lease_epoch == 0
    end

    test "{:already_running, pid} for a second session on the same run", %{run: run} do
      gate!()
      assert {:ok, pid} = SolverSession.start_run(run)
      assert_receive {:awaiting, awaiter}, 5_000

      assert {:error, {:already_running, ^pid}} = SolverSession.start_run(run)
      assert SessionSupervisor.active_count() == 1

      send(awaiter, :release)
      assert :normal = await_down(pid)
    end
  end

  describe "the tasks a session starts" do
    defp task_children, do: Task.Supervisor.children(AshEnterprise.TaskSupervisor)

    test "after a solver session stops, no task it started is alive", %{run: run} do
      gate!()
      assert {:ok, pid} = SolverSession.start_run(run)
      assert_receive {:awaiting, awaiter}, 5_000
      assert Process.alive?(awaiter)

      ref = Process.monitor(awaiter)
      GenServer.stop(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^awaiter, _reason}, 5_000

      assert Task.Supervisor.children(SessionSupervisor.task_supervisor()) == []
    end

    test "after a solver session test ends, AshEnterprise.TaskSupervisor has no children it started",
         %{run: run} do
      before = task_children()

      gate!()
      assert {:ok, pid} = SolverSession.start_run(run)
      assert_receive {:awaiting, awaiter}, 5_000
      assert SessionSupervisor.active_count() == 1

      ref = Process.monitor(awaiter)
      GenServer.stop(pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^awaiter, _reason}, 5_000

      assert task_children() -- before == []
      refute awaiter in task_children()
    end

    test "a cancelled session's cancel task is shut down with it", %{run: run} do
      gate!()
      Application.put_env(:ash_enterprise, :planning_test_cancel_gate, self())
      assert {:ok, pid} = SolverSession.start_run(run)
      assert_receive {:awaiting, _awaiter}, 5_000

      assert :ok = SolverSession.cancel(run.id)
      assert_receive {:cancelling, canceller}, 5_000

      ref = Process.monitor(canceller)
      GenServer.stop(pid, :shutdown)

      assert_receive {:DOWN, ^ref, :process, ^canceller, _reason}, 5_000
      assert Task.Supervisor.children(SessionSupervisor.task_supervisor()) == []
    end
  end

  describe "outcomes" do
    test "a scripted optimal solve is recorded optimal and complete, with a sealed payload", %{
      run: run
    } do
      script!(%{fake_outcome: :optimal, fake_candidates: [%{"x" => 1}, %{"x" => 2}]})
      ended = start_and_finish(run)

      assert ended.solve_status == :optimal
      assert ended.optimality == :optimal
      assert ended.complete?
      assert ended.lease_epoch == 1
      assert is_nil(ended.lease_expires_at)
      assert is_nil(ended.session_pid)

      {:ok, loaded} =
        Ash.load(ended, :result_payload, tenant: ended.organization_id, authorize?: false)

      assert %{"candidates" => [_, _]} = Jason.decode!(loaded.result_payload)
    end

    test "a timeout with an incumbent is feasible and incomplete, never optimal", %{run: run} do
      script!(%{fake_outcome: :feasible, fake_candidates: [%{"x" => 1}]})
      ended = start_and_finish(run)
      assert {ended.solve_status, ended.complete?, ended.optimality} == {:feasible, false, :none}
      assert ended.outcome_reason == :time_limit
    end

    test "proven unsatisfiability is infeasible and complete", %{run: run} do
      script!(%{fake_outcome: :infeasible})
      ended = start_and_finish(run)
      assert {ended.solve_status, ended.complete?} == {:infeasible, true}
    end

    test "a timeout with no incumbent is unknown, not infeasible", %{run: run} do
      script!(%{fake_outcome: :unknown})
      ended = start_and_finish(run)
      assert {ended.solve_status, ended.complete?} == {:unknown, false}
    end

    test "a backend start error is recorded as the classified terminal outcome", %{run: run} do
      script!(%{fake_outcome: {:error, :invalid_model}})
      assert start_and_finish(run).solve_status == :invalid_model
    end

    test "a governor error from the backend is recorded backend_failed with its reason", %{
      run: run
    } do
      script!(%{fake_outcome: {:error, :resource_governor_unavailable}})
      ended = start_and_finish(run)

      assert {ended.solve_status, ended.outcome_reason} ==
               {:backend_failed, :resource_governor_unavailable}
    end

    test "the heavy slot is released when the session ends", %{run: run} do
      start_and_finish(run)
      Process.sleep(50)
      assert PlanningRegistry.heavy_slots_in_use() == 0
    end
  end

  describe "cancel ladder" do
    test "cancel/1 stops the solver through the backend and records :cancelled", %{run: run} do
      gate!()
      assert {:ok, pid} = SolverSession.start_run(run)
      assert_receive {:awaiting, _awaiter}, 5_000

      assert :ok = SolverSession.cancel(run.id)
      assert :normal = await_down(pid)

      ended = reload(run)
      assert ended.solve_status == :cancelled
      refute ended.complete?
      assert ended.optimality == :none
      assert PlanningRegistry.lookup(run.id) == :error
    end

    test "cancel/1 with no live session is {:error, :not_running}" do
      assert {:error, :not_running} = SolverSession.cancel(Ecto.UUID.generate())
    end

    test "a cancel recorded on the row is honoured by the next poll tick", %{w: w, run: run} do
      gate!()
      assert {:ok, pid} = SolverSession.start_run(run)
      assert_receive {:awaiting, _awaiter}, 5_000

      Planning.request_planning_run_cancel!(reload(run), %{reason: :requested}, w.oban)
      assert :normal = await_down(pid)

      ended = reload(run)
      assert ended.solve_status == :cancelled
      assert ended.cancellation_reason == :requested
    end
  end

  describe "lease" do
    test "poll ticks renew the lease under the same epoch while the solve runs", %{run: run} do
      gate!()
      assert {:ok, pid} = SolverSession.start_run(run)
      assert_receive {:awaiting, awaiter}, 5_000

      first = reload(run)
      assert first.lease_epoch == 1
      assert %DateTime{} = first.lease_expires_at

      # lease_ms 900 renews every >= 300ms; poll_ms 40.
      Process.sleep(700)
      renewed = reload(run)
      assert renewed.lease_epoch == 1
      assert DateTime.compare(renewed.lease_expires_at, first.lease_expires_at) == :gt
      assert is_nil(renewed.solve_status)

      send(awaiter, :release)
      assert :normal = await_down(pid)
      assert reload(run).solve_status == :optimal
    end

    test "a lease taken over by the sweep stops the session without it writing", %{run: run} do
      gate!()
      assert {:ok, pid} = SolverSession.start_run(run)
      assert_receive {:awaiting, _awaiter}, 5_000

      # Someone else ends the run (the lease sweep): the session notices on its next tick.
      :ok = AshEnterprise.Planning.LeaseSweeper.expire(reload(run))
      assert :normal = await_down(pid)

      ended = reload(run)
      assert {ended.solve_status, ended.outcome_reason} == {:unknown, :lease_lost}
    end
  end
end
