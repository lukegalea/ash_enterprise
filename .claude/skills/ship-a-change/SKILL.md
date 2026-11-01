---
name: ship-a-change
description: "Use when taking a change from a worktree to main in this repository: the worktree pre-flight, which checks to run locally, CI on a ci/** branch as the full-suite gate, rebasing when other work lands first, and working beside other sessions on a shared host."
---

# Shipping a change

Finished work goes straight to `main`; there is no review branch. CI decides whether it is finished.
The whole test suite runs one test at a time on a developer host and takes about two hours. CI runs
it on parallel shards (balanced by recorded timings) in about 25 minutes, together with every other
blocking check. So CI is the
full-suite gate, and a change reaches CI before it reaches `main` by being pushed to a `ci/**` branch.

## 1. Work in your own worktree

The main checkout often holds someone else's uncommitted or stashed work. Never commit from it.

```bash
git fetch -q origin
git worktree add --detach .claude/worktrees/<name> origin/main
cp -a --reflink=auto deps _build .claude/worktrees/<name>/   # seed the build, then `mix deps.get`
```

Give each worktree its own `DB_NAME`, `MIX_TEST_PARTITION` and, if it runs a server, `PORT`.

Before the first test run, do the pre-flight:

- **Postgres.** The process listening on `$PGPORT` must be this checkout's cluster:
  `readlink /proc/<pid>/cwd` is `.devenv/state/postgres` under the main checkout. When that cluster is
  down, the port can belong to another project's database. Inside a worktree, export `PGPORT`
  explicitly; devenv falls back to 5432 there. If the port belongs to someone else, stop. Never start,
  stop or move another project's cluster.
- **Disk.** Check that at least 20 GB is free (`df -h`). Each worktree carries its own `_build`, and
  a full disk has crashed both the cluster and the runs that depended on it.
- **Deps.** If `mix.lock` changed since the worktree was seeded, run `mix deps.get`.

## 2. Run the local checks, not the whole suite

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix ash.codegen --check
scripts/iron-laws.sh
mix test <the test files you added or affected>
mix test.durability <the durability files you added or affected>   # by file, see docs/DURABILITY-TESTS.md
```

If you touched a seam between substrates or a dependency pin, also run the battery (`mix platform_battery`
in `battery/`, see `battery/README.md`). Every run uses the one `platform_battery_test` database, so
run it one at a time.

Do not run the whole `mix test` or the whole `mix test.durability` locally to prove a change. CI does
that faster, and on a shared host a whole-suite run holds the machine for hours.

When several worktrees test at once, they share the cluster's connection limit. The test pool size is
twice the scheduler count, so keep runs modest: `ELIXIR_ERL_OPTIONS="+S 4"` and `--max-cases 4`.

## 3. Let CI run on a `ci/**` branch

```bash
git fetch origin && git rebase origin/main
git push -f origin HEAD:refs/heads/ci/<name>      # full refname: a detached HEAD cannot create the branch otherwise; force only on your own ci/ branch
gh run list --branch ci/<name> --limit 1          # find the run
gh run watch <run-id>                             # block until it finishes
```

- **A job goes red.** Reproduce that file locally with `mix test <file>`, fix it, and push to the
  same `ci/` branch again. The Dialyzer job is advisory; add no new warnings.
- **Everything is green.** Fetch again. If `main` moved and the rebase touches files you changed,
  push to `ci/` and wait again. Otherwise:

```bash
git push origin HEAD:main          # never force-push main
gh run watch <main's run-id>
git push origin --delete ci/<name>
```

Waiting means blocking on `gh run watch` (or a bounded `until` loop), not checking a log every few
seconds. A run can sit queued for a while when several branches are in CI at once; that is still far
shorter than a local whole-suite run.

## 4. When other work lands first

- **`mix.lock` conflict.** Take `main`'s lock and redo your `mix deps.update`. Re-sync the battery pins
  (`elixir scripts/battery-pins-check.exs --sync`, then `mix deps.get` in `battery/`). If a
  dependency's usage rules changed, run `mix usage_rules.sync --yes` and commit `AGENTS.md` and
  `.claude/skills` with the lock.
- **Migration or resource-snapshot conflict.** Drop *your* generated migration and snapshots, finish
  the rebase, and run `mix ash.codegen <name>` again. Never hand-edit a generated migration.
- **Documentation index conflict.** Keep both rows.

After a rebase that touched your area, recompile and rerun your tests before pushing.

## 5. Sharing the host

Other sessions, long-running services and their databases run on the same machine.

- Stop only processes you started, by PID, after checking what the PID is. Never kill by pattern
  (`pkill`, `killall`).
- Never stop services you did not create.
- Remove your worktree when your work has landed, and drop the test databases it created.
