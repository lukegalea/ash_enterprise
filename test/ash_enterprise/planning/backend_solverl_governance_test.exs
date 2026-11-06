defmodule AshPlanning.Backend.SolverlGovernanceTest do
  # Refusal paths happen before any spawn, so no minizinc is needed.
  use ExUnit.Case, async: true

  alias AshPlanning.{Error, Problem}
  alias AshPlanning.Backend.Solverl

  @fake_prlimit "/usr/bin/prlimit"

  setup do
    path = Path.join(System.tmp_dir!(), "gov_#{System.unique_integer([:positive])}.mzn")
    File.write!(path, "var 1..2: x; solve satisfy;")
    on_exit(fn -> File.rm(path) end)
    {:ok, model: path}
  end

  defp start(model, opts) do
    Solverl.start(%Problem{model_path: model}, opts)
  end

  test "missing governor refuses with resource_governor_unavailable before spawn", %{model: model} do
    assert {:error,
            %Error{kind: :resource_governor_unavailable, details: %{reason: :governor_missing}}} =
             start(model, governor_lookup: fn -> nil end)
  end

  test "limit above ceiling refuses with limit_exceeds_ceiling", %{model: model} do
    assert {:error, %Error{kind: :limit_exceeds_ceiling}} =
             start(model,
               limits: %{memory_bytes: 999_000_000_000},
               governor_lookup: fn -> @fake_prlimit end
             )
  end

  test "any executable override is refused", %{model: model} do
    for exe <- [
          "/usr/bin/minizinc",
          "/usr/bin/env prlimit",
          "/usr/bin/prlimit /usr/bin/minizinc",
          "#{@fake_prlimit} --as=268435456 /opt/minizinc/bin/minizinc"
        ],
        key <- [:minizinc_executable, :executable] do
      assert {:error,
              %Error{
                kind: :invalid_problem,
                details: %{reason: :executable_override_not_permitted}
              }} = start(model, [{key, exe}, {:governor_lookup, fn -> @fake_prlimit end}])
    end
  end

  test "override smuggled in the problem map is refused", %{model: model} do
    problem = %{"minizinc_executable" => "/usr/bin/minizinc", "model_path" => model}

    assert {:error, %Error{details: %{reason: :executable_override_not_permitted}}} =
             Solverl.start(problem, governor_lookup: fn -> @fake_prlimit end)
  end

  test "adapter builds the governed command itself from limits" do
    problem = %Problem{
      model_path: "x.mzn",
      limits: %{memory_bytes: 268_435_456},
      opts: %{governor_lookup: fn -> @fake_prlimit end}
    }

    case Solverl.resolve_executable(problem) do
      {:ok, cmd} -> assert String.starts_with?(cmd, "#{@fake_prlimit} --as=268435456 ")
      {:error, %Error{kind: :solver_unavailable}} -> :ok
    end
  end
end
