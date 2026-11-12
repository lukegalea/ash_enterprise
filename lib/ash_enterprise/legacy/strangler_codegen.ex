defmodule AshEnterprise.Legacy.StranglerCodegen do
  @moduledoc """
  Makes `mix ash.codegen` cover the strangler compatibility layer.

  The view, key index and ledger DDL for the legacy estate comes from
  `AshStrangler.Migration`, not from AshPostgres: a strangled resource declares
  `migrate? false` (its `table` names the compatibility *view*, and codegen
  would emit a `create table` for that name), and with `migrate? false` there
  is no resource snapshot for `custom_statements` to hang off either. That is
  why `mix ash_strangler.gen.migration` is its own task — and it is why the CI
  gate, `mix ash.codegen --check`, has been blind to the layer: a mapping
  change that left the installed DDL stale was only caught later, by
  `mix ash_strangler.check --strict` against a database in CI's e2e job.

  This extension exports `codegen/1`, the callback `mix ash.codegen` calls on
  every extension in use. It renders the current statements **from compiled
  resources, with no database** (`AshStrangler.Migration.statements/1`, the
  same function the generator task writes migrations from) and compares them,
  statement for statement, against a committed snapshot of what the newest
  installed strangler migration contains:

    * `--check` — when the snapshot is stale or missing, reports each affected
      resource by name and raises `Ash.Error.Framework.PendingCodegen` (the
      same exception AshPostgres raises, so the task's handling — and the
      "Pending Code Generation Detected" message — is unchanged).
    * `--dry-run` — prints the pending statements.
    * `<name>` — writes `priv/repo/migrations/<timestamp>_<name>_strangler.exs`
      and refreshes the snapshots. The timestamp is allocated strictly after
      the newest file already in the migrations directory and strictly after
      AshPostgres's own in-process counter, so it cannot land on the version
      AshPostgres writes in the same run, whichever extension runs first. The
      `_strangler` suffix also keeps
      `AshEnterprise.Legacy.CodegenIsolationTest` true: a migration that
      mentions `legacy.*` must be recognizably the strangler's own.
    * `--dev` — refused while anything is pending; see "Why there is no
      `--dev`" below.

  ## Why there is no `--dev`

  AshPostgres's dev mode exists so its final named run can roll the dev
  migrations back and squash them against resource snapshots. The strangler
  layer has no snapshots to squash and its statements are idempotent
  (`CREATE OR REPLACE`, `IF NOT EXISTS`), so a dev-suffixed migration would
  only add a second name for DDL the final run rewrites, plus a
  `schema_migrations` row orphaned when the final file replaces the dev one.
  During development run `mix ash.codegen <name>` directly. The refusal only
  fires when strangler statements are actually pending: an iteration that
  changed nothing in the mapping still passes through.

  ## Where the snapshots live, and what they record

  `priv/strangler_snapshots/<repo underscored>/<underscored resource>.json`,
  one file per rendered resource, because a stale mapping is reported by name
  and per-file diffs are reviewable. Each file records the `name` and `up` of
  every statement the renderer produces for that resource — what the newest
  installed strangler DDL contains, proven at seed time by comparing against
  the applied migrations and by re-applying the statements to a migrated
  database inside a rolled-back transaction. `down` is not recorded: the
  renderer derives it from `up`, so it can never disagree.

  The extension declares no DSL sections. It is attached to the
  `AshEnterprise.Legacy` domain so its intent — the strangler layer is part of
  that domain's contract — is visible where the strangled resources are
  declared; `mix ash.codegen` in fact discovers every `Spark.Dsl.Extension`
  in the application, attached or not.
  """

  use Spark.Dsl.Extension

  @behaviour Ash.Extension

  @migration_suffix "strangler"
  @snapshot_root "priv/strangler_snapshots"

  @doc """
  Called by `mix ash.codegen`, which appends `--name <name-or-nil>` to its own
  arguments before handing them to every extension.
  """
  @impl Ash.Extension
  def codegen(argv) do
    # Other extensions' flags (`--snapshots-only`, `--no-format`, ...) flow
    # through here too; the ones that matter to this hook are checked below.
    {opts, _invalid, _positional} =
      OptionParser.parse(argv,
        strict: [name: :string, check: :boolean, dry_run: :boolean, dev: :boolean]
      )

    cond do
      opts[:dev] -> dev(opts)
      opts[:check] -> check()
      opts[:dry_run] -> dry_run()
      true -> generate(name!(opts[:name]))
    end
  end

  @doc """
  Every rendered resource whose statements disagree with its snapshot, or that
  has no snapshot yet.

  Options:

    * `:snapshot_root` — where snapshots are read from; defaults to
      `priv/strangler_snapshots/<repo>` under the project root.
  """
  @spec pending(keyword()) :: [
          %{
            resource: module(),
            snapshot_path: String.t(),
            status: :missing | :invalid | :changed,
            summary: String.t(),
            pending: [{String.t(), String.t()}]
          }
        ]
  def pending(opts \\ []) do
    root = opts[:snapshot_root] || snapshot_root()

    rendered()
    |> Enum.map(fn {resource, statements} -> compare(root, resource, statements) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Every resource `AshStrangler.Migration` renders for this application's
  domains, mapped to its current statements (`%{name: atom, up: binary, down:
  binary}`, exactly what `mix ash_strangler.gen.migration` writes migrations
  from). No database is involved.
  """
  @spec rendered() :: %{
          optional(module()) => [
            %{required(:name) => atom(), required(:up) => String.t(), required(:down) => String.t()}
          ]
        }
  def rendered do
    Map.new(resources(), fn resource ->
      {resource, AshStrangler.Migration.statements(resource)}
    end)
  end

  @doc "Where `resource`'s snapshot lives under `root`."
  @spec snapshot_path(String.t(), module()) :: String.t()
  def snapshot_path(root, resource) do
    Path.join(root, key(resource) <> ".json")
  end

  @doc "Where `resource`'s snapshot lives for this project."
  @spec snapshot_path(module()) :: String.t()
  def snapshot_path(resource), do: snapshot_path(snapshot_root(), resource)

  @doc """
  Writes every rendered resource's current statements to its snapshot file, and
  returns the paths written.

  Called by `mix ash.codegen <name>` after it writes the migration those
  statements belong in, and once by hand to seed the initial snapshots.
  """
  @spec write_snapshots!(keyword()) :: [String.t()]
  def write_snapshots!(opts \\ []) do
    root = opts[:snapshot_root] || snapshot_root()

    for {resource, statements} <- Enum.sort(rendered()) do
      path = snapshot_path(root, resource)
      File.mkdir_p!(Path.dirname(path))

      doc = %{
        "resource" => inspect(resource),
        "statements" =>
          Enum.map(normalize(statements), fn {name, up} -> %{"name" => name, "up" => up} end)
      }

      File.write!(path, Jason.encode!(doc, pretty: true) <> "\n")
      path
    end
  end

  @doc """
  A migration version for a new strangler migration: strictly greater than
  every version already in `dir`, strictly greater than the current second,
  and strictly greater than AshPostgres's last allocated version when this
  process has seen one.

  AshPostgres's generator takes "the current second" and protects only against
  itself, through the `:ash_postgres_last_migration_timestamp` process key.
  Whichever of the two extensions runs first in one `mix ash.codegen`, the
  other's file must not land on the same version, or Ecto refuses the
  directory ("migrations can't be executed, migration version ... is
  duplicated"). Scanning `dir` covers this hook running second; publishing our
  version into that same counter covers this hook running first, because it is
  the mechanism AshPostgres itself uses between its own writes.
  """
  @spec next_version(String.t()) :: String.t()
  def next_version(dir) do
    now = utc_now_version()

    from_files =
      case newest_version(dir) do
        0 -> []
        newest -> [bump(Integer.to_string(newest))]
      end

    from_counter =
      case Process.get(:ash_postgres_last_migration_timestamp) do
        nil -> []
        last -> [bump(last)]
      end

    version = Enum.max([now | from_files ++ from_counter])
    Process.put(:ash_postgres_last_migration_timestamp, version)
    version
  end

  # -- the codegen modes -------------------------------------------------------

  defp check do
    case pending() do
      [] ->
        :ok

      pending ->
        Mix.shell().error(pending_report(pending))

        raise Ash.Error.Framework.PendingCodegen,
          diff: Enum.map(pending, &{&1.snapshot_path, &1.summary})
    end
  end

  defp dry_run do
    case pending() do
      [] ->
        Mix.shell().info("Strangler compatibility layer is up to date.")

      pending ->
        Mix.shell().info(dry_run_report(pending))
    end
  end

  defp dev(opts) do
    case pending() do
      [] ->
        Mix.shell().info(
          "Strangler compatibility layer is up to date; --dev is a no-op for it."
        )

      pending ->
        Mix.shell().error(pending_report(pending))
        Mix.raise(dev_refusal(opts))
    end
  end

  defp generate(name) do
    case pending() do
      [] ->
        Mix.shell().info("Strangler compatibility layer is up to date; no migration written.")

      pending ->
        path = write_migration!(name)
        write_snapshots!()

        case pending() do
          [] ->
            Mix.shell().info("""

            Covers #{length(pending)} resource(s): #{Enum.map_join(pending, ", ", &inspect(&1.resource))}

            Review it, then run `mix ecto.migrate`.
            """)

          still ->
            Mix.raise(
              "wrote #{path} and refreshed the snapshots, but these still differ: " <>
                Enum.map_join(still, ", ", &inspect(&1.resource))
            )
        end
    end
  end

  defp write_migration!(name) do
    repo = repo!()
    dir = migrations_path(repo)
    version = next_version(dir)
    module_name = "#{inspect(repo)}.Migrations.#{Macro.camelize("#{name}_#{@migration_suffix}")}"

    source = AshStrangler.Migration.render(module_name, resources())

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{version}_#{name}_#{@migration_suffix}.exs")
    Mix.Generator.create_file(path, source, force: true)
    path
  end

  defp name!(name) do
    if is_binary(name) and name != "" do
      name
    else
      Mix.raise("""
      Name must be provided when generating a strangler migration, unless `--check`, `--dry-run` or `--dev` is also provided.

      Please provide a name, for example:

          mix ash.codegen <name>
      """)
    end
  end

  defp dev_refusal(_opts) do
    """
    ash_strangler's compatibility layer has no `--dev` mode.

    AshPostgres uses `--dev` so its final named run can roll the dev migrations back and
    squash them against resource snapshots. The strangler layer has no snapshots to squash
    and its statements are idempotent (`CREATE OR REPLACE`, `IF NOT EXISTS`), so a dev
    migration would only add a second name for DDL the final run rewrites, plus a
    `schema_migrations` row orphaned when the dev file is replaced.

    Run `mix ash.codegen <name>` instead: it writes the strangler migration and refreshes
    the snapshots in the same run. AshPostgres's own dev files, if any were written before
    this refusal, are unaffected.
    """
  end

  # -- comparison --------------------------------------------------------------

  defp compare(root, resource, statements) do
    path = snapshot_path(root, resource)
    current = normalize(statements)

    case read_snapshot(path) do
      {:ok, stored} ->
        if stored == current do
          nil
        else
          {summary, pending} = diff(stored, current)
          entry(resource, path, :changed, summary, pending)
        end

      {:error, :missing} ->
        entry(resource, path, :missing, "no snapshot yet", current)

      {:error, reason} ->
        entry(resource, path, :invalid, "unreadable snapshot: #{reason}", current)
    end
  end

  defp entry(resource, path, status, summary, pending) do
    %{
      resource: resource,
      snapshot_path: path,
      status: status,
      summary: summary,
      pending: pending
    }
  end

  defp read_snapshot(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, "cannot read: #{inspect(reason)}"}

      {:ok, body} ->
        case decode_snapshot(body) do
          {:ok, statements} -> {:ok, statements}
          :error -> {:error, "expected {\"resource\", \"statements\": [{\"name\", \"up\"}]}"}
        end
    end
  end

  defp decode_snapshot(body) do
    with {:ok, %{"statements" => statements}} <- Jason.decode(body),
         statements when is_list(statements) <- statements,
         true <-
           Enum.all?(
             statements,
             &match?(%{"name" => n, "up" => u} when is_binary(n) and is_binary(u), &1)
           ) do
      {:ok, Enum.map(statements, &{&1["name"], &1["up"]})}
    else
      _ -> :error
    end
  end

  # Statements are compared positionally: the order is the dependency order the
  # renderer guarantees (schema, view, index, triggers, ledger), so a reorder
  # is drift the same way a changed body is.
  defp diff(stored, current) do
    zipped = Enum.zip(stored, current)

    changed =
      for {{stored_name, stored_up}, {current_name, current_up}} <- zipped,
          stored_name != current_name or stored_up != current_up do
        {current_name, current_up}
      end

    added = Enum.drop(current, length(stored))
    removed = max(length(stored) - length(current), 0)

    summary =
      [
        if(changed == [], do: nil, else: "changed: #{Enum.map_join(changed, ", ", &elem(&1, 0))}"),
        if(added == [], do: nil, else: "added: #{Enum.map_join(added, ", ", &elem(&1, 0))}"),
        if(removed == 0, do: nil, else: "removed: #{removed}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    {summary, changed ++ added}
  end

  defp normalize(statements) do
    Enum.map(statements, fn statement ->
      {to_string(statement.name), String.trim_trailing(statement.up)}
    end)
  end

  # -- reporting ---------------------------------------------------------------

  defp pending_report(pending) do
    Enum.map_join(pending, "\n\n", fn entry ->
      """
      Pending strangler compatibility DDL for #{inspect(entry.resource)}: #{entry.summary}
      snapshot: #{relative(entry.snapshot_path)}
      """
    end) <>
      """

      Run `mix ash.codegen <name>` to write the migration and refresh the snapshots,
      or `mix ash.codegen --dry-run` to see the pending statements.
      """
  end

  defp dry_run_report(pending) do
    Enum.map_join(pending, "\n\n", fn entry ->
      body =
        Enum.map_join(entry.pending, "\n", fn {name, up} ->
          String.trim_trailing("""
          -- #{name}
          #{up}
          """)
        end)

      String.trim_trailing("""
      #{inspect(entry.resource)}: #{entry.summary}
      #{body}
      """)
    end)
  end

  defp relative(path) do
    Path.relative_to(path, File.cwd!())
  rescue
    _ -> path
  end

  # -- paths and discovery -----------------------------------------------------

  defp resources do
    # `mix ash.codegen` runs `compile` but not `app.config`, and the order the
    # extensions run in is not guaranteed — AshPostgres may not have loaded the
    # config yet. Reading `:ash_domains` needs it.
    Mix.Task.run("app.config")

    app = Mix.Project.config()[:app]
    AshStrangler.Migration.resources(Application.get_env(app, :ash_domains, []))
  end

  defp repo! do
    app = Mix.Project.config()[:app]

    Application.get_env(app, :ecto_repos, [])
    |> List.first()
    |> case do
      nil ->
        Mix.raise("no ecto_repos configured for #{inspect(app)}; cannot place the strangler migration")

      repo ->
        repo
    end
  end

  defp migrations_path(repo) do
    priv = repo.config()[:priv] || Path.join("priv", repo_dir(repo))
    Path.join([File.cwd!(), priv, "migrations"])
  end

  defp snapshot_root do
    Path.join([File.cwd!(), @snapshot_root, repo_dir(repo!())])
  end

  defp repo_dir(repo) do
    repo |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp key(resource) do
    resource |> Module.split() |> Enum.map_join("_", &Macro.underscore/1)
  end

  # -- version arithmetic --------------------------------------------------------

  defp newest_version(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.flat_map(fn
      <<version::binary-size(14), "_", _rest::binary>> ->
        if String.match?(version, ~r/^\d{14}$/), do: [String.to_integer(version)], else: []

      _ ->
        []
    end)
    |> case do
      [] -> 0
      versions -> Enum.max(versions)
    end
  end

  defp utc_now_version do
    NaiveDateTime.utc_now() |> format_version()
  end

  defp bump(version) do
    <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), h::binary-size(2),
      mi::binary-size(2), s::binary-size(2)>> = version

    NaiveDateTime.new!(
      Date.new!(String.to_integer(y), String.to_integer(mo), String.to_integer(d)),
      Time.new!(String.to_integer(h), String.to_integer(mi), String.to_integer(s))
    )
    |> NaiveDateTime.add(1, :second)
    |> format_version()
  end

  defp format_version(datetime) do
    Calendar.strftime(datetime, "%Y%m%d%H%M%S")
  end
end
