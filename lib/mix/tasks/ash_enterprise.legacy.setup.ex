defmodule Mix.Tasks.AshEnterprise.Legacy.Setup do
  @shortdoc "Creates and seeds the simulated legacy schema"

  @moduledoc """
  Creates and seeds the simulated legacy schema in `legacy.*`.

      mix ash_enterprise.legacy.setup
      mix ash_enterprise.legacy.setup --schema-only

  Plain SQL applied with `psql`, **not** an Ecto migration and **not** an Ash
  resource. That is the point rather than an implementation detail: the whole
  exercise is about a schema this application does not own, and the moment
  `legacy.*` appears in `priv/repo/migrations` the demo is lying about the
  situation it demonstrates. See `priv/legacy/README.md`.

  `psql` rather than `AshEnterprise.Repo.query!/1` because the scripts are
  multi-statement and contain `DO $$ ... $$` blocks; Postgrex's extended
  protocol refuses more than one command per query, and splitting the files on
  semicolons would corrupt the dollar-quoted bodies. The connection settings are
  read from the repo's own config, so this still honours the dynamically
  allocated `PGPORT` (see `CLAUDE.md`).

  Idempotent. `schema.sql` uses `IF NOT EXISTS` throughout and `seed.sql`
  truncates before inserting, so re-running resets the legacy estate to its
  seeded state without accumulating rows.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [schema_only: :boolean])

    files =
      if opts[:schema_only] do
        ["schema.sql"]
      else
        ["schema.sql", "seed.sql"]
      end

    Enum.each(files, &apply_file/1)

    Mix.shell().info([:green, "legacy schema ready", :reset, " (schema `legacy`)"])
  end

  defp apply_file(name) do
    path = Application.app_dir(:ash_enterprise, ["priv", "legacy", name])
    path = if File.exists?(path), do: path, else: Path.join(["priv", "legacy", name])

    Mix.shell().info("applying priv/legacy/#{name}")

    {output, status} =
      System.cmd("psql", psql_args() ++ ["--file", path], stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("""
      psql failed applying priv/legacy/#{name} (exit #{status}):

      #{output}
      """)
    end
  end

  defp psql_args do
    config = AshEnterprise.Repo.config()

    [
      "--host",
      to_string(config[:hostname] || "localhost"),
      "--port",
      to_string(config[:port] || 5432),
      "--username",
      to_string(config[:username] || "postgres"),
      "--dbname",
      to_string(Keyword.fetch!(config, :database)),
      # Fail on the first error rather than reporting success after a partial
      # apply, and keep the output to what actually matters.
      "--set",
      "ON_ERROR_STOP=1",
      "--quiet",
      "--no-psqlrc"
    ]
  end
end
