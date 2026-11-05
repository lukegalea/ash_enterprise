defmodule AshEnterprise.FaultsTest do
  @moduledoc """
  Fault points do nothing until armed, let through the passes they were armed to skip, fire as
  armed, and go quiet after the number of firings they were armed for, counted across processes.
  """

  use ExUnit.Case, async: false

  alias AshEnterprise.Faults
  alias AshEnterprise.Faults.Fault

  setup do
    on_exit(&Faults.disarm_all/0)
  end

  test "compiled in under the test configuration" do
    assert Faults.enabled?()
  end

  test "an unarmed point does nothing" do
    assert Faults.point(:faults_test_unarmed) == :ok
  end

  test ":raise raises the fault, once by default" do
    Faults.arm(:faults_test_raise, :raise)

    assert_raise Fault, "fault point :faults_test_raise fired", fn ->
      Faults.point(:faults_test_raise)
    end

    assert Faults.point(:faults_test_raise) == :ok
  end

  test ":exit exits the calling process with the point's name" do
    Faults.arm(:faults_test_exit, :exit)

    assert catch_exit(Faults.point(:faults_test_exit)) == {:fault, :faults_test_exit}
  end

  test ":kill kills the calling process, and says which one first" do
    Faults.arm(:faults_test_kill, :kill, notify: self())

    {pid, ref} = spawn_monitor(fn -> Faults.point(:faults_test_kill) end)

    assert_receive {:fault_fired, :faults_test_kill, ^pid}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "a point armed for n firings fires n times across processes, then goes quiet" do
    Faults.arm(:faults_test_counted, :raise, times: 3)

    fired =
      1..10
      |> Task.async_stream(fn _ ->
        try do
          Faults.point(:faults_test_counted)
        rescue
          Fault -> :fired
        end
      end)
      |> Enum.count(&match?({:ok, :fired}, &1))

    assert fired == 3
  end

  test "a point armed to skip n passes lets n through, then fires" do
    Faults.arm(:faults_test_skip, :raise, skip: 2)

    assert Faults.point(:faults_test_skip) == :ok
    assert Faults.point(:faults_test_skip) == :ok
    assert_raise Fault, fn -> Faults.point(:faults_test_skip) end
    assert Faults.point(:faults_test_skip) == :ok
  end

  test "a disarmed point does nothing" do
    Faults.arm(:faults_test_disarmed, :raise, times: :infinity)
    Faults.disarm(:faults_test_disarmed)

    assert Faults.point(:faults_test_disarmed) == :ok
  end
end
