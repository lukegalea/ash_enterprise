defmodule Mix.Tasks.PlatformBattery do
  @moduledoc """
  The cross-substrate integration battery runner.

      mix platform_battery

  1. Ensures the `vendorpm_platform_battery_test` database exists (creates
     it if missing — idempotent).
  2. Runs pending migrations (idempotent).
  3. Runs the battery's ExUnit suite IN-PROCESS.
  4. Exits nonzero if any test failed.

  Deterministic: no network, no host-specific configuration beyond the
  standard PGHOST/PGPORT/PGUSER/PGPASSWORD env vars.
  """

  use Mix.Task

  @shortdoc "Run the cross-substrate platform integration battery"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    ensure_database!()
    start_repo!(Battery.Repo)
    start_repo!(AshEvidence.Repo)

    migrate!(Battery.Repo)

    run_battery()
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
    ExUnit.start()

    ExUnit.configure(
      autorun: false,
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
