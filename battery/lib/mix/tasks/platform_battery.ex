defmodule Mix.Tasks.PlatformBattery do
  @moduledoc """
  The cross-substrate integration battery runner.

      mix platform_battery

  1. Ensures the `vendorpm_platform_battery_test` database exists (creates
     it if missing — idempotent).
  2. Runs pending migrations (idempotent).
  3. Runs the battery's ExUnit suite.
  4. Exits nonzero if any test failed.

  Deterministic: no host-specific configuration beyond the standard
  PGHOST/PGPORT/PGUSER/PGPASSWORD env vars.

  Two execution modes. Inside the battery project (its own mix.exs) the
  suite runs in-process. Consumed as a dependency — the point of the
  battery (ADR 0056) — the task SHELLS OUT to the battery project instead:
  several substrates bind their repos at COMPILE time (`config.exs`), so a
  foreign host's config would win over the battery's reference
  instantiation and the scenarios would run against the host's database.
  The battery's own `_build`/`deps` inside the dep checkout keep that
  instantiation identical everywhere; its `mix.lock` pins every substrate,
  so the first run fetches them and later runs are offline.
  """

  use Mix.Task

  @shortdoc "Run the cross-substrate platform integration battery"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    if Mix.Project.config()[:app] == :ash_enterprise_battery do
      Mix.Task.run("compile")

      ensure_database!()
      start_repo!(Battery.Repo)
      start_repo!(AshEvidence.Repo)

      migrate!(Battery.Repo)

      run_battery()
    else
      run_as_host_dependency()
    end
  end

  # Consumed as a dep: delegate to the battery's own project, which owns
  # its config, its compile-time bindings, its database and its deps.
  defp run_as_host_dependency do
    dir = battery_dep_dir()
    Mix.shell().info("platform_battery: shelling out to #{dir}")

    unless File.dir?(Path.join(dir, "deps")) do
      # First run only: the battery's mix.lock pins every substrate, so
      # this is deterministic; later runs are offline.
      System.cmd(mix_bin(), ["deps.get"], cd: dir, into: IO.stream(:stdio, :line))
    end

    {_output, status} =
      System.cmd(mix_bin(), ["platform_battery"], cd: dir, into: IO.stream(:stdio, :line))

    if status == 0 do
      :ok
    else
      exit({:shutdown, status})
    end
  end

  defp battery_dep_dir do
    case Enum.find(Mix.Dep.cached(), &(&1.app == :ash_enterprise_battery)) do
      %Mix.Dep{} = dep ->
        # Sparse git deps check out into the host's deps dir like any other.
        Path.join(Mix.Project.deps_path(), "#{dep.app}")

      nil ->
        Mix.raise("platform_battery: :ash_enterprise_battery is not a dependency of this project")
    end
  end

  defp mix_bin do
    System.find_executable("mix") || Mix.raise("platform_battery: mix not on PATH")
  end

  defp ensure_database! do
    case Battery.Repo.__adapter__().storage_up(Battery.Repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> Mix.raise("could not create the battery database: #{inspect(reason)}")
    end
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Mix.raise("could not start #{inspect(repo)}: #{inspect(reason)}")
    end
  end

  defp migrate!(repo) do
    # Migrations run outside the sandbox (pool still in :auto).
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)

    Ecto.Migrator.run(repo, migrations_path(repo), :up, all: true, log: :info)

    Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
    :ok
  end

  defp migrations_path(_repo) do
    Path.join(:code.priv_dir(:ash_enterprise_battery), "repo/migrations")
  end

  defp run_battery do
    # autorun: false from the start — ExUnit.start/1 registers an at-exit
    # that would otherwise re-run the (now-cleared) suite at VM shutdown
    # and print a confusing "Result: 0 tests" after the real result.
    ExUnit.start(autorun: false)

    ExUnit.configure(
      include: ExUnit.configuration()[:include],
      exclude: ExUnit.configuration()[:exclude] || []
    )

    test_files =
      "test/base_integration"
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
      |> Enum.sort()

    Enum.each(test_files, &Code.require_file(Path.absname(&1)))

    results = ExUnit.run()

    failures = Map.get(results, :failures, 0)
    invalid = Map.get(results, :invalid, 0)

    if failures > 0 or invalid > 0 do
      IO.puts([
        "\nPlatform battery FAILED: #{failures} failures, #{invalid} invalid"
      ])

      exit({:shutdown, 1})
    else
      IO.puts([
        "\nPlatform battery green: #{Map.get(results, :total, 0)} tests, #{Map.get(results, :skipped, 0)} skipped"
      ])

      :ok
    end
  end
end
