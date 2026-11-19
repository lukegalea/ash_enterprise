# Runbook: importing a large CSV

There is one way in for a large file: the MDM staged import at `/app/mdm/import`. A file there passes through a
mapping, staging, matching and the steward queue, as a small one does. No generic "import into any table" path exists,
because it would skip the mapping, the stewardship and the person gate.

| | |
|---|---|
| Rows per file | up to 50,000 by default (`max_rows`); a larger file is refused before anything lands |
| File size | up to 30 MB by default (`max_file_size`) |
| Who | a person whose grants let them open an import batch (`ImportBatch.open`) on an active mapping |
| Where the rows go | raw source records (bizev `SourceRecord`), then staged rows of the batch, then matching |

## What happens

1. **Upload.** The browser sends the file. The wizard copies it into the upload store
   (`AshEnterprise.Mdm.BulkImport.store_upload/1`) under a fresh id, then reads it once as a stream to get the header,
   a ten-row sample and the row count. The rows never enter the LiveView's memory: its assigns hold the header, the
   sample and the count. A file over the cap is refused at this step, with a message that says to split it.
2. **Mapping.** As for any import: pick an active mapping or draft one, and a person activates it.
3. **Run.** The batch opens **as the person**. If their grants do not allow it, the import is refused, no batch opens
   and nothing lands. Otherwise `AshEnterprise.Mdm.BatchWorker` is enqueued with the batch id and the upload id (string
   keys, ids only). The worker lands the file 1,000 rows at a time (`chunk_size`) under the batch's own tenant and
   dataset, and writes the landed and refused counts and a cursor onto the batch after each chunk. It lands for about
   a minute (`slice_ms`), then the job snoozes and the next execution carries on from the cursor. When the last row is
   done, the batch records when (`landed_at`), the worker stages every landed row as of that instant, and moves on to
   matching. Staging and matching share each execution's minute too: past it, the job snoozes and the next execution
   carries on, skipping rows already staged and rows already matched. The stored file is removed once the batch has
   staged and matched.

Why slices: Oban's Lifeline (`rescue_after`, 5 minutes in `config/config.exs`) takes a job that has been executing for
longer than that for an orphan and starts it again. One execution that lands 50,000 rows runs past it, and the two
copies then write the same batch (measured: the batch failed on a stale write). A slice stays well inside it. A retried job never lands a file twice: once
`landed_at` is set, landing is skipped and the file is not needed.

An execution that raises (a deadlock, a dropped connection, a row that fails matching) is retried by Oban, up to three
attempts, and the retry carries on from the cursor the batch records: the batch keeps its status, landed rows stay
landed, and staged rows are not staged again. A snooze between slices is not an attempt. Only the last attempt's
failure ends the batch: it is marked failed with the reason, its lineage run fails, and the stored file is removed.

The wizard polls the job and shows the landed, refused and staged counts. The batch board (`/app/mdm/batches`, then
the batch) shows the same counters.

## Rows that do not land

A row that cannot land is not a failed import. The rest of the file lands, and each refused row is recorded as an
`AshEnterprise.Mdm.ImportRowRefusal` with its spreadsheet row number (the header is row 1) and the reason. The reason
names the rule the row broke and does not quote the row's values:

| Reason | Cause |
|---|---|
| `malformed row: N fields where the header has M` | the row has a different number of fields from the header |
| `inadmissible region: residency "x" is not admitted into the landing region` | the row's `residency` column (matched without regard to case; `residency_column` renames it) declares a residency the landing region does not admit (ADR 0042, docs/runbooks/residency.md) |
| `this row's dataset already holds a newer observation of it` | the same row was landed later than this file claims to be |

The batch's page lists the refused rows in row order, and the table's **Export CSV** button downloads them as
`refused-rows.csv`. To fix them, correct those rows in the file and import the whole file again: rows that already
landed land again as no-ops (see below).

Refused rows are readable by whoever may read the batch: the seeded Administrator and Data steward roles.

## Importing the same file again

The row key is the row's position in the file (`upload-<index>`), within the tenant and the dataset name. Landing the
same file again into the same dataset re-observes the same identities, and bizev's temporal landing writes nothing
for a row whose content has not changed: no new source record and no new period. A row whose content changed gets a
new version from the new fetch instant. Inserting or deleting a row in the middle of the file shifts the keys of the
rows after it; when a file has a stable id column, a mapping keyed on it is the safer way to re-import.

## Configuration

    config :ash_enterprise, AshEnterprise.Mdm.BulkImport,
      max_rows: 50_000,
      max_file_size: 30_000_000,
      chunk_size: 1_000,
      slice_ms: 60_000,
      residency_column: "residency"
      # upload_dir: defaults to "ash_enterprise_imports" under the system temp dir

`upload_dir` holds a file from the upload until its batch has staged. The node that served the wizard writes it and
the node that runs the `mdm` queue reads it, so a deployment with more than one node puts `upload_dir` on storage
every node shares; otherwise the job fails with "the upload for batch ... could not be landed". The wizard removes a
file it stored and never ran when the view closes. A file older than a day in that directory belongs to no running
import, and can be removed.

## What is recorded

Each landing slice is one telemetry span, `[:ash_enterprise, :mdm, :bulk_import, :land]`. Its metadata is the batch
id and tenant, and when it stops, the landed and refused counts so far and `done?`; the span carries the duration. The batch carries its
correlation id through landing, staging and matching, and emits the usual lineage start, complete or fail events
(`mdm`, `batch:<id>`). A refused row is not an audit event: it records no change to anyone's data, and the refusal row
already says what happened.

## Measured

The durability tier (`test/ash_enterprise/durability/bulk_import_test.exs`, run by the `durability` CI job) imports a
file of 50,000 two-column rows through a real Oban queue, each row committed, and prints the times. The first CI run
(run 44264838504, ubuntu-latest) landed the 50,000 rows in 342 s over six slices (146 rows a second), and the batch
reached staged 616 s after it opened (the fixture's tenant has no match rule set, so matching is skipped). The test
fails above three times those numbers. A development laptop (two schedulers, a shared Postgres) took 283 s and
524 s. That is a fixture on one machine, not a claim about a deployment; a deployment we operate measures its own
import once and records it in the ledger's answer.

Landing is one bizev `land` per row: a read of the identity's current version and, for a new identity, a write that
opens its period. That per-row path is where the time goes, and it is linear in the file. A batched land would be a
change to bizev.

Two things measured on the way, so nobody measures them again:

- In the SQL sandbox (one uncommitted transaction for the whole test) landing degrades with the table: Postgres keeps
  the generic plan it cached for the identity lookup while the table was empty, and no ANALYZE replaces it. 50,000
  rows took 18 minutes there (45 rows a second). With commits the table is analyzed as it grows, which is why the
  50,000-row test lives in the durability tier.
- One job execution that landed 50,000 rows ran past Lifeline's five minutes, a second copy started, and the batch
  failed on a stale write. That is why the worker runs in slices.
