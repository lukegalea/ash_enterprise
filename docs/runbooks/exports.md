# Runbook: exporting data as CSV

Two ways out, both under the same policies as every other read: the reader gets exactly the rows their grants reach,
in their own tenant, and nothing else. Neither is a privileged path.

| Path | For | Size | Who |
|---|---|---|---|
| The **Export CSV** button on a table surface | the filtered list a person is looking at | up to 10,000 rows | anyone who can open the surface |
| `GET /api/exports/:type` | a whole exposed collection, in bulk | unbounded, streamed | a person holding the export privilege, with an API key |

The audit log has its own export, with the chain columns that make it verifiable: `mix ash_enterprise.audit.export`
(`AshEnterprise.Audit.Export`).

## From a surface

The business units, teams, users and audit trail surfaces declare an `export` block (ash_a2ui). The button re-reads
the table as the signed-in person, through its read action, with the current search and filters, and hands the
browser a CSV. The person can untick columns; they cannot add one the surface did not declare. A surface whose door is
closed to a person never mounts for them, so there is no button to press.

The cap is the library's default, 10,000 rows, because the file travels over the page's socket. A larger set goes
through the API.

## From the API

    curl -H "Authorization: Bearer aek_..." https://<host>/api/exports/teams -o teams.csv

| Answer | When |
|---|---|
| 401 | no key, or a key that is unknown, expired, revoked or owned by a deactivated person |
| 403 | the key's owner does not hold the export privilege |
| 404 | the type is not exportable |
| 200, `text/csv` | otherwise: a header, then one line per row the owner's grants reach |

The privilege is checked before the type, so a person without it learns nothing about what is exportable.

**What is exportable.** The resources the API exposes, named as their JSON:API routes name them: `business_units`,
`positions` and `teams` (`AshEnterprise.Exports.Csv.types/0`). The list is declared in code; a resource joins it by a
reviewed line. The columns are the resource's public attributes, the ones the API serves. A cell a field policy
withholds from the reader is written empty. A text cell that starts with `=`, `+`, `-` or `@` is written with a
leading `'`, so a spreadsheet shows it rather than evaluating it.

**How it streams.** The rows are read in keyset pages of 250 through the resource's paged `:list` read, as the key's
owner, and each page is sent as one HTTP chunk as soon as it is read. The set is never held in memory. A client that
disconnects stops the read.

## The export privilege

Exporting is `read` on `AshEnterprise.Exports.Export`, a grant like any other, held at `:global` (it has no rows to
narrow). The seeded Administrator role holds it; no other seeded role does. Give it to someone else by adding it to a
role in the role admin.

Opening an export is a person's act: a system actor, the engines and an automation principal acting for a person are
refused it (`human_only`, ADR 0059), whatever grants they carry.

Existing tenants' Administrator roles pick the privilege up when the release that adds it boots
(`AshEnterprise.Platform.PrivilegeSync` writes the catalogue and regrants every Administrator); nothing to run by
hand.

## What is recorded

Each export emits one telemetry span, `[:ash_enterprise, :exports, :csv]`, whose metadata is the type and, when it
stops, the number of rows written; the span carries the duration. It holds no value, no person and no tenant. There
is no export row in the database. The API key that was used is recorded on each request the way every API request is.

## Measured

The scale job (`test/ash_enterprise/scale/fifty_thousand_test.exs`) exports 50,000 teams through `GET
/api/exports/teams` on every CI run and prints the time, the number of reads and the reading process's peak memory.
The first run (CI run 44131463312) wrote 50,001 rows, 10.7 MB, in 5.7 s, in 201 reads of teams, and the reading
process never held more than 1.5 MB. That is the fixture on a CI runner, not a claim about a deployment; a deployment
we operate measures its own once and records it in the ledger's answer.
