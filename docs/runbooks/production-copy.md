# Runbook: a pseudonymised copy of production

Written 2026-11-17, against [ADR 0032](../adr/0032-anonymization-config-is-generated.md). Code: the `greenmask`
blocks on the resources (`lukegalea/ash_greenmask`), the generated [`greenmask.yml`](../../greenmask.yml),
`Mix.Tasks.AshEnterprise.Greenmask.Drill` and [`scripts/greenmask-drill`](../../scripts/greenmask-drill). Tests:
`test/ash_enterprise/anonymization/greenmask_config_test.exs`, and the drill in the `backup-restore-drill` CI job.

A copy made this way is **pseudonymised, not anonymised**. The values that name a person are replaced, but the copy
keeps every row's shape, every key and every timestamp, and a hashed value can be matched by anyone who holds the
salt and a list of guesses. Treat a copy as personal data that is harder to read, not as data that is safe.

## What a copy holds

`greenmask.yml` is generated from the resources by `mix ash_greenmask.gen.config`; CI fails when it has drifted
(`--check`), and generation fails when a stored resource has a `sensitive?` attribute with no position. Its header
lists everything that passes through and why. In short:

| What | In the copy |
| --- | --- |
| Sign-in addresses, names, credential numbers, provider ids | replaced: a deterministic hash under the salt, or an address at `example.com` |
| Password hashes | one bcrypt hash of a random secret nobody kept, on every account: no production password signs in |
| The legacy users table's password digests, salts, remember-me and activation tokens | a digest no password produces, and nulls: no legacy password or token carries over |
| API keys, sign-in tokens, provider identities, lockouts | the tables, empty |
| Erasure keys | `wrapped_key` replaced, so no value sealed under a scope can be opened, even with production's master key |
| Values sealed under an erasure scope (`encrypted_*`) | the ciphertext, unopenable for the reason above |
| Values sealed under the application vault (the assistant's threads, turns and drafts) | the ciphertext, readable by anyone who also holds production's vault key. Never give a copy's environment that key |
| The audit log and its archive, the business-event ledger and its simulation twin, the compliance event log | the tables, empty. A value transform breaks a hash chain, and their `data` and `metadata` hold the recorded records' values inside JSON no column transform reaches |
| Large objects | not copied (`no-blobs`); their metadata (oid, owner) is |
| Tables no resource declares (`schema_migrations`, Oban's jobs, a package's own tables) | as they are |
| Process and decision definitions | as they are: a tenant's own design, not personal data |
| MDM raw landings (`mdm_source_records.raw_payload`), staged rows (`mdm_staged_records.mapped` and `validation_findings`), a mapping's findings and its proposer's raw output | replaced with an empty JSON object: a landed row's keys are a spreadsheet's own headers, so no column transform can name the values inside. The rows, their identities, periods and links stay |
| Other free-form JSON columns no resource positions (92 on 2026-11-18, listed in `greenmask_config_test.exs`) | as they are, until each gets a transform or a stated reason. The name heuristic below cannot see inside a JSON value, so a test lists them and fails on a new one that has neither |

The tenant keys, ids and timestamps are copied unchanged. A copy is therefore linkable to production row for row by
anyone who holds both.

## Salt custody

`GREENMASK_GLOBAL_SALT` is key material: with it and a list of candidate values, a hashed column can be reversed by
brute force. It never lives in the repository, in `greenmask.yml` or in a CI log.

- Keep one salt per destination in a host-only secret file beside the erasure master key (mode 0600, readable by the
  operator who makes copies), and export it only into the environment of the one `greenmask dump` that uses it.
- A new salt for a destination makes its next copy unlinkable to the last. Reuse one only where two copies must agree.
- CI makes a fresh random salt per run and never prints it.

Where a deployment's salts live is a decision for the deployment's owner and is not made here.

## Making a copy

1. Check the binary: `greenmask --version` must say 0.2.23 (CI pins it by sha256), and `pg_dump` must be no older
   than the server.
2. Write a runtime config outside the repository: a `common` section (`pg_bin_path`, `tmp_dir`), a `storage`
   section, `restore.pg_restore_options.exit-on-error: true`, then the contents of `greenmask.yml`, which is the
   `dump` section. Pass the connections as `DUMP_PG_DUMP_OPTIONS_DBNAME` and `RESTORE_PG_RESTORE_OPTIONS_DBNAME`
   and the password as `PGPASSWORD`, never in the file. `Mix.Tasks.AshEnterprise.Greenmask.Drill` writes exactly
   this file; read it for the shape.
3. `greenmask validate --warnings` against the source. Never pass `--data` against production: it prints rows.
4. `greenmask dump`, then `greenmask restore latest` into the destination, with the destination's salt exported.
5. Delete the dump directory. It holds the transformed rows and nothing else, but it is still a copy.

**One tenant per copy** is the intended default and is **not built**: greenmask can scope a dump with
`subset_conds`, and the generator does not emit them. Until it does, a copy is the whole database, and goes only to
an environment that may hold every tenant's pseudonymised rows.

## The drill

`scripts/greenmask-drill` proves a copy, two ways.

**Sentinel mode** (CI, on every push, in the `backup-restore-drill` job, against the seeded database): it makes a
scratch database from the source as a template, writes a sentinel token into every row of every column
`greenmask.yml` transforms, into a large object and into a control table nothing transforms, validates, copies and
restores. A transformed table the seeded database left empty first gets one synthetic row (a placeholder of each
column's type where one is required; foreign keys are not checked while planting), so every transform is exercised.
It fails if the token survives anywhere but the control table (every text, JSON and binary column of the copy, every
large object and every dump data file is searched), if an excluded table has rows in the copy, if the control did
not survive (the scan would be blind), or if any transformed column had no rows to plant into (`--allow-empty
schema.table.column` names one that may, and the report lists it). The source database is never written.

**Known-value mode**, for a deployment's own database: `scripts/greenmask-drill --known-values --source-url URL`
opens the source read-only, samples up to 50 distinct values from each transformed text column, copies through
greenmask into `<database>_gm_copy` on the local server, and fails if any sampled value is in the same column of the
copy. The values stay in memory; the report carries counts only. Drop the copy afterwards unless it is the copy
you meant to make.

## Drill log

| Date | Database | Mode | Result |
| --- | --- | --- | --- |
| — | the CI seed | sentinel | runs on every push; see the `backup-restore-drill` job |

No copy of a deployment we operate has been made or drilled yet. Doing so reads that deployment's personal data,
transformed in flight, into a scratch database, and waits for its owner's agreement. Record each run here.

## Not covered

- Uniqueness: greenmask's hash does not guarantee it. A collision on a unique column fails the restore loudly
  (`exit-on-error`); nothing is silently merged.
- Keys: ids are copied as they are. A uuid could be replaced deterministically (`random_uuid` with
  `engine: "hash"`; greenmask's `Hash` refuses uuid columns), and no resource asks for it.
- Free text inside a column the model does not mark: the inventory's name heuristic (`DataInventory.looks_personal?`)
  and `sensitive?` are what decide which columns get a position, and a person named in a column neither flags passes
  through. JSON columns are listed instead (above), because a name says nothing about what a map holds.
