defmodule AshEnterprise.Planning.Integration.SolverlAdapterTest do
  @moduledoc """
  The real Solverl/MiniZinc backend, no doubles.

  Run only in a Coder workspace with minizinc 2.10.1 on `PATH` (the spike's tested version) and
  `prlimit` present: `mix test --only integration test/ash_enterprise/planning/integration`.
  Without a `minizinc` executable every test here is skipped, so the default suite stays green
  on a host that has none.

  Models are tiny and synthetic, written to a temp directory per test.
  """

  use ExUnit.Case, async: false

  alias AshEnterprise.Planning.Backend.{Error, Problem, SolveResult, Solverl}

  @moduletag :integration
  @moduletag skip:
               if(System.find_executable("minizinc"),
                 do: false,
                 else: "minizinc not installed: run in a Coder workspace with minizinc 2.10.1"
               )
  @moduletag timeout: 120_000

  @decimal_model "var 0.0..10.0: x;\nconstraint x = 1.25;\nsolve minimize x;\n"
  @tiny_model "var 1..3: x;\nsolve satisfy;\n"
  @checker_ok "int: x;\nconstraint x >= 1;\n"
  @checker_bad "int: x;\nconstraint x > 100;\n"
  @unsat_model "var 1..3: x;\nconstraint x > 5;\nsolve satisfy;\n"
  @hog_model "array[1..20000000] of var 0..1: a;\nsolve satisfy;\n"
  # A 13-mark Golomb ruler: minutes of branch-and-bound, far past any test deadline.
  @long_model """
  include "alldifferent.mzn";
  int: n = 13;
  array[1..n] of var 0..300: mark;
  constraint mark[1] = 0;
  constraint forall(i in 1..n-1)(mark[i] < mark[i+1]);
  constraint alldifferent([mark[j] - mark[i] | i in 1..n, j in i+1..n]);
  solve minimize mark[n];
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "solverl_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp write!(dir, name, text) do
    path = Path.join(dir, name)
    File.write!(path, text)
    path
  end

  defp solve!(problem, opts \\ []) do
    assert {:ok, ref} = Solverl.start(problem, opts)
    assert {:ok, %SolveResult{} = result} = Solverl.await(ref, 60_000)
    result
  end

  defp limits, do: %{memory_bytes: 1_000_000_000, time_limit_ms: 30_000}

  defp alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ") |> List.last() |> String.first() != "Z"
      {:error, _} -> false
    end
  end

  describe "decimal purity" do
    test "an objective of 1.25 arrives as a Decimal, never a Float", %{dir: dir} do
      model = write!(dir, "decimal.mzn", @decimal_model)
      result = solve!(%Problem{model_path: model, limits: limits()})

      assert result.status == :feasible
      assert [%{objective: objective, data: data} | _] = result.payload.candidates
      assert %Decimal{} = objective
      assert Decimal.equal?(objective, Decimal.new("1.25"))
      refute is_float(objective)
      assert %Decimal{} = data["x"]
      refute is_float(data["x"])
    end
  end

  describe "checker" do
    test "a correct candidate passes the checker", %{dir: dir} do
      model = write!(dir, "tiny.mzn", @tiny_model)
      checker = write!(dir, "tiny.mzc.mzn", @checker_ok)
      result = solve!(%Problem{model_path: model, checker_path: checker, limits: limits()})

      assert [_ | _] = result.payload.candidates
      assert Enum.all?(result.payload.candidates, &(&1.checker_ok? == true))
    end

    test "a corrupted candidate is reported incorrect (checker UNSATISFIABLE)", %{dir: dir} do
      model = write!(dir, "tiny.mzn", @tiny_model)
      checker = write!(dir, "tiny_bad.mzc.mzn", @checker_bad)
      result = solve!(%Problem{model_path: model, checker_path: checker, limits: limits()})

      assert [_ | _] = result.payload.candidates

      for candidate <- result.payload.candidates do
        assert candidate.checker_ok? == false
        assert candidate.checker_output =~ "UNSATISFIABLE"
      end
    end
  end

  describe "outcome honesty" do
    test "proven unsatisfiability is :infeasible and complete", %{dir: dir} do
      model = write!(dir, "unsat.mzn", @unsat_model)
      result = solve!(%Problem{model_path: model, limits: limits()})

      assert {result.status, result.complete?, result.outcome_reason} ==
               {:infeasible, true, :unsat}
    end

    test "a model over the memory cap fails only the solver, classified resource_exhausted", %{
      dir: dir
    } do
      model = write!(dir, "hog.mzn", @hog_model)

      assert {:ok, ref} =
               Solverl.start(
                 %Problem{
                   model_path: model,
                   limits: %{memory_bytes: 268_435_456, time_limit_ms: 20_000}
                 },
                 []
               )

      assert {:error, %Error{kind: :resource_exhausted}} = Solverl.await(ref, 60_000)
      # The BEAM and the backend carry on: a following solve still works.
      ok = write!(dir, "tiny.mzn", @tiny_model)
      assert %SolveResult{status: :feasible} = solve!(%Problem{model_path: ok, limits: limits()})
    end
  end

  describe "governance refusals" do
    test "no governor refuses before any solver exists", %{dir: dir} do
      model = write!(dir, "tiny.mzn", @tiny_model)

      assert {:error, %Error{kind: :resource_governor_unavailable}} =
               Solverl.start(%Problem{model_path: model, limits: limits()},
                 governor_lookup: fn -> nil end
               )
    end

    test "a declared memory limit above the ceiling is refused", %{dir: dir} do
      model = write!(dir, "tiny.mzn", @tiny_model)

      assert {:error, %Error{kind: :limit_exceeds_ceiling}} =
               Solverl.start(
                 %Problem{model_path: model, limits: %{memory_bytes: 999_000_000_000}},
                 []
               )
    end
  end

  describe "cancel ladder" do
    test "cancel mid-solve leaves no surviving solver descendants", %{dir: dir} do
      model = write!(dir, "long.mzn", @long_model)

      assert {:ok, ref} =
               Solverl.start(
                 %Problem{
                   model_path: model,
                   limits: %{memory_bytes: 1_000_000_000, time_limit_ms: 110_000}
                 },
                 []
               )

      assert {:ok, ospid} = Solverl.os_pid(ref)
      wait_for_descendants(ospid)

      snapshot = Solverl.snapshot_tree(ospid)
      assert map_size(snapshot) >= 1
      pids = Map.keys(snapshot)
      assert Enum.all?(pids, &alive?/1)

      assert :ok = Solverl.cancel(ref)

      assert {:ok, %SolveResult{outcome_reason: :stopped, complete?: false}} =
               Solverl.await(ref, 30_000)

      # The ladder verifies the tree itself; assert the same from the outside.
      Process.sleep(200)
      assert Enum.reject(pids, &alive?/1) == pids
      assert Solverl.snapshot_tree(ospid) == %{}
    end
  end

  defp wait_for_descendants(ospid, attempts \\ 100) do
    cond do
      map_size(Solverl.snapshot_tree(ospid)) > 1 -> :ok
      attempts == 0 -> :ok
      true -> Process.sleep(100) && wait_for_descendants(ospid, attempts - 1)
    end
  end
end
