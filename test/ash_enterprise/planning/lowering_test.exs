defmodule AshEnterprise.Planning.LoweringTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Planning.Lowering

  @weekday %{
    "workStartMinute" => 540,
    "workEndMinute" => 1020,
    "bufferMinutes" => 15,
    "breakAfterMinutes" => 120,
    "breakMinutes" => 15
  }
  @off %{@weekday | "workStartMinute" => 0, "workEndMinute" => 0, "bufferMinutes" => 0}

  defp requirements do
    Map.new(Lowering.weekdays(), fn d ->
      {d, if(d in ~w(saturday sunday), do: @off, else: @weekday)}
    end)
  end

  defp at(day, hour, minute \\ 0),
    do:
      DateTime.new!(Date.add(~D[2026-11-09], day), Time.new!(hour, minute, 0, {0, 6}), "Etc/UTC")

  defp input(extra \\ %{}) do
    Map.merge(
      %{
        week_start: at(0, 0),
        cutoff: at(0, 0),
        tasks: [
          %{id: "t1", duration_minutes: 100, due_at: at(2, 17)},
          %{id: "t2", duration_minutes: 30, due_at: nil}
        ],
        meetings: [
          %{id: "m1", starts_at: at(0, 10), ends_at: at(0, 10, 30), mandatory?: true, priority: 3}
        ],
        pins: [%{id: "p1", starts_at: at(3, 9), ends_at: at(3, 10)}],
        requirements: requirements()
      },
      extra
    )
  end

  test "slot arithmetic matches the slot domain" do
    assert {:ok, p} = Lowering.lower(input())
    assert p["day_work_start"] == [36, 36, 36, 36, 36, 0, 0]
    assert p["day_work_end"] == [68, 68, 68, 68, 68, 0, 0]
    assert p["day_buffer"] == [1, 1, 1, 1, 1, 0, 0]
    assert {p["break_after_slots"], p["break_slots"]} == {8, 1}
    assert {p["m_start"], p["m_end"]} == {[40], [42]}
    assert {p["pin_start"], p["pin_end"]} == {[3 * 96 + 36], [3 * 96 + 40]}
    assert p["t_dur"] == [7, 2]
    assert p["t_due"] == [2 * 96 + 68, 672]
    assert p["t_release"] == [0, 0]
    assert p["ids"] == %{"tasks" => ["t1", "t2"], "meetings" => ["m1"], "pinned" => ["p1"]}
  end

  test "nothing is placed before the cutoff, and busy intervals round conservatively" do
    assert {:ok, p} =
             Lowering.lower(
               input(%{
                 cutoff: at(1, 9, 1),
                 meetings: [
                   %{
                     id: "m",
                     starts_at: at(0, 10, 5),
                     ends_at: at(0, 10, 20),
                     mandatory?: false,
                     priority: 1
                   }
                 ]
               })
             )

    assert p["t_release"] == [96 + 36 + 1, 96 + 36 + 1]
    assert {p["m_start"], p["m_end"], p["m_mandatory"]} == {[40], [42], [false]}
  end

  test "a weekday without requirements is a refusal" do
    assert {:error, {:requirements, "friday"}} =
             Lowering.lower(input(%{requirements: Map.delete(requirements(), "friday")}))
  end

  test "assignments lift index-aligned and solver_data drops non-parameters" do
    {:ok, p} = Lowering.lower(input())
    data = %{"scheduled" => [true, false], "start" => [45, 0], "attended" => [true]}
    assert {:ok, [t1, t2, m1]} = Lowering.assignments(p, data)
    assert t1 == %{"kind" => "task", "id" => "t1", "scheduled" => true, "start_slot" => 45}
    assert t2["scheduled"] == false
    assert m1 == %{"kind" => "meeting", "id" => "m1", "attended" => true}
    assert {:error, :shape} = Lowering.assignments(p, %{"scheduled" => [true]})
    refute Map.has_key?(Lowering.solver_data(Map.put(p, "snapshot", %{})), "snapshot")
  end

  test "solver_data drops empty lists (MiniZinc 2.10 rejects array0d)" do
    p = %{
      "n_prec" => 0,
      "prec_before" => [],
      "slot_minutes" => 15,
      "t_dur" => [3, 2]
    }

    data = Lowering.solver_data(p)
    refute Map.has_key?(data, "prec_before")
    assert data["slot_minutes"] == 15
    assert data["t_dur"] == [3, 2]
  end

  test "week_start is the Monday of the UTC week" do
    assert Lowering.week_start(at(3, 15)) == at(0, 0)
  end
end
