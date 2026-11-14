# Runbook: backup, restore, and evidence retention

Written 2026-11-12 for q48 (coming back from losing the database), q36 (how long evidence is kept and where it
lives after ninety days), q11 (rebuilding state from the log) and q51 (a control that runs on a schedule).
Code: `mix ash_enterprise.backup.drill` (`scripts/backup-restore-drill`), `AshEnterprise.Release.audit_verify/2`,
`AshEnterprise.Release.audit_export/1`, `AshEnterprise.Audit.Retention`,
`AshEnterprise.Audit.ChainVerifyWorker`, `AshEnterprise.Compliance.FreshnessSweepWorker`,
`AshEnterprise.Audit.ClearRecordsForReplay`. Tests and checks: the `backup-restore-drill` CI job,
`test/ash_enterprise/audit/retention_test.exs`, `test/ash_enterprise/audit/replay_drill_test.exs`,
`test/ash_enterprise/compliance/continuous_verification_test.exs`.

This repository is a template. It ships the drill, the retention policy and the scheduled checks. A deployment
supplies the rest: where backups are stored, how often they are taken, who is paged, and the recovery point and
recovery time it commits to. Nothing here sets those numbers.

## The drill

```bash
scripts/backup-restore-drill                                   # the current MIX_ENV's database
scripts/backup-restore-drill --keep --dump /backups/drill.dump --json drill.json
```

1. It opens a `REPEATABLE READ` transaction, exports its snapshot, counts the rows of every table in that snapshot,
   and runs `pg_dump --format=custom --snapshot=<it>`. The counts and the dump describe the same instant, so the
   drill can run against a live database.
2. It restores the dump into a fresh database, `<database>_restore_drill` (dropped first if a previous drill left
   one), with `pg_restore --exit-on-error`.
3. It checks the copy: every table has the same number of rows as the snapshot, and every audit chain verifies on
   the copy (`AshEvents.Chain.verify_all/1` over `AshEnterprise.Audit.EventLog`, hot and archived events together).
4. It prints the dump's size and SHA-256 and how long the dump and the restore took (`--json` writes the same report
   as JSON). On success it drops the restored database (`--keep` keeps it) and deletes the dump unless `--dump`
   names a path. On any difference it exits non-zero and keeps the restored database for inspection.

It needs `pg_dump` and `pg_restore` no older than the server (`PG_DUMP` and `PG_RESTORE` override the binaries), and
a role that can create databases.

CI runs the drill on every push, against a freshly seeded database on the service Postgres (the
`backup-restore-drill` job). That proves the dump and restore path and the checks still work. It is measured at
seed scale, so its timings say nothing about a real database's recovery time.

### Running it on a deployment

The drill is an operator-host task. It needs `pg_dump`, `pg_restore`, a role that can create databases and a source
checkout (it is a Mix task), and the release image has none of them: it carries no Mix and no PostgreSQL client.
Run it from a host that has the checkout and the client tools, pointed at the deployment's database or at a restored
copy of it (`DATABASE_URL`), on a schedule the deployment chooses, with `--dump` pointing at the backup store and
`--json` kept as the record of the drill. The JSON is the evidence for A1.3 (recovery testing). Its timings are this
database's restore time on this server; the recovery point is how often the dump runs, plus WAL archiving if the
deployment adds it. Neither is set here.

What a release does run is the audit checks, as release commands:

```bash
bin/ash_enterprise eval "AshEnterprise.Release.audit_verify()"
bin/ash_enterprise eval 'AshEnterprise.Release.audit_verify(nil, halt?: true)'   # exit 1 on a break
bin/ash_enterprise eval 'AshEnterprise.Release.audit_export(tenant: "<organization id>", as: "<auditor email>", from: "2026-01-01", to: "2027-01-01", out: "/tmp/audit-2026")'
```

They are what `mix ash_enterprise.audit.verify` and `mix ash_enterprise.audit.export` do (one body each, called from
both), and they write nothing but the export's directory.

### Restoring for real

1. Stop the application, so nothing writes while you restore.
2. `createdb <name>` and `pg_restore --exit-on-error --no-owner --no-acl --dbname=<name> <dump>`, from a host
   with the PostgreSQL client tools.
3. Verify before pointing anything at it: start the release against the restored database
   (`DATABASE_URL=... bin/ash_enterprise eval "AshEnterprise.Release.audit_verify(nil, halt?: true)"`) and
   expect no findings; the row counts should match the drill report for that dump. From a source checkout,
   `DB_NAME=<name> mix ash_enterprise.audit.verify` does the same.
4. Point the application at it (`DATABASE_URL`, or `DB_NAME` in development) and start it.

A restore brings back what the dump held. Erasure keys are rows like any other: a scope shredded after the dump was
taken is unshredded by the restore (its wrapped key is back), so shred it again after restoring
(`docs/runbooks/crypto-shredding.md`).

## Retention: ninety days hot, never purged before four hundred

`AshEnterprise.Audit.RetentionWorker` runs daily (`config/config.exs` crontab).

- **Ninety days hot.** Audit events and evidence artifacts older than `hot_days` (90) move to the archive tables,
  `audit_event_archive` and `evidence_artifact_archive`, in the same database. A move copies the rows, compares the
  copy with the hot rows (the same count on both sides, every column equal, the same SHA-256 digest over their
  hashes in order, and every archived artifact's content hashing to its `hash`), and only then deletes the hot rows,
  in one transaction. A failed comparison deletes nothing and is recorded as a failed `AshEnterprise.Audit.ArchiveRun`
  with its reason. The audit log's trigger refuses a `DELETE` of any row that has no identical archived copy or is
  younger than ninety days, whoever asks.
- **What stays hot.** The tail of each audit chain (so the next event has a row to link to), and the newest artifact
  of each organization, control and collector (the freshness sweep reads the hot table). An audit chain with a
  verification finding is not moved at all.
- **Never purged before four hundred days.** Nothing is purged unless `purge_after_days` is configured, and a value
  under 400 is refused. The archive tables' triggers refuse to delete anything younger than 400 days, and refuse
  every `UPDATE`. A purge of the audit archive records the hash of the last event it removed, and the chain verifier
  starts what remains from there.
- **Not partitioned.** ADR 0024 accepted monthly partitions for this; none was ever created, so the archive is a
  pair of tables rather than detached partitions. A deployment that wants the archive on cheaper storage can move
  those tables to another tablespace, or dump them.

To see what retention has done: `AshEnterprise.Audit.list_archive_runs!/1`, or the `audit_archive_runs` table.

## The scheduled checks

- `AshEnterprise.Audit.ChainVerifyWorker`, daily: verifies every chain and stores the result as an evidence artifact
  for CC4.1 and CC7.2, findings included.
- `AshEnterprise.Compliance.FreshnessSweepWorker`, hourly: `ash_compliance`'s freshness sweep for every organization.
  A criterion whose evidence is missing or stale (a daily control with no artifact in the last day) becomes an
  `:unknown` finding with gap `evidence_freshness`, and is resolved when fresh evidence arrives.

## Rebuilding state from the log

AshEvents replay re-runs every event in the log onto a clean slate. `AshEnterprise.Audit.ClearRecordsForReplay`
clears the resources named in its configuration and refuses unless `allow?` is true, which only dev and test set.
It also refuses, before deleting anything, when the log holds events of an audited resource the list does not name,
when events have moved to the archive (replay reads only the hot log), or when the list names the audit log or an
unaudited resource.

```elixir
AshEnterprise.Audit.EventLog
|> Ash.ActionInput.for_action(:replay, %{}, actor: AshEnterprise.Platform.SystemActor.replay(), authorize?: false)
|> Ash.run_action()
```

Proven for the configured resource (business units) by `replay_drill_test.exs`. A full rebuild of every resource has
not been run: each audited resource's actions would have to replay cleanly, and a database that has archived events
cannot be rebuilt from the hot log alone. Take a backup first.
