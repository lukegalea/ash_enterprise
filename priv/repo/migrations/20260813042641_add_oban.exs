defmodule AshEnterprise.Repo.Migrations.AddOban do
  use Ecto.Migration

  # Oban's migration does not go through Ecto's `:migration_default_prefix`:
  # `Oban.Migration.up/1` takes its own `:prefix` and defaults it to "public"
  # independently of where the rest of the migrations are running. So when this
  # application is hosted inside another system's database (see config/dev.exs
  # and ASH_SCHEMA), leaving this alone puts `oban_jobs` in `public` while every
  # other table lands in the owned schema -- the one table shared with whatever
  # else lives in that database.
  #
  # Read from the same Oban config the supervisor reads, so the migration and the
  # running queues cannot disagree about which schema holds the jobs.
  # NOT `prefix/0`: `use Ecto.Migration` imports `Ecto.Migration.prefix/0`, and a
  # local function of the same name and arity is a compile error, not a shadow.
  defp oban_prefix do
    :ash_enterprise
    |> Application.get_env(Oban, [])
    |> Keyword.get(:prefix, "public")
  end

  def up, do: Oban.Migration.up(prefix: oban_prefix())

  def down, do: Oban.Migration.down(version: 1, prefix: oban_prefix())
end
