# Upstream exceptions

Code or UI that stays below its placement step on purpose. The rule is
[ADR 0070](adr/0070-upstream-first-placement.md), section 8. No row, no merge.

One row per item. A workaround for a dependency bug does not go here: it goes in
[BLEEDING-EDGE.md](BLEEDING-EDGE.md) section 3.

| Path | Step skipped | Reason | Upstream issue or PR | Owner | Exit condition | Remove by | Added |
|---|---|---|---|---|---|---|---|

Columns:

- **Path:** the file or module that is the exception.
- **Step skipped:** the placement step it should have used (1 to 4, or U1 to U3 for UI).
- **Reason:** what was tried and why upstream is wrong or too early. "It was faster" is not a reason.
- **Upstream issue or PR:** a link. A row added under ADR 0070 section 7 (d) links the open draft PR.
- **Owner:** the person who merged the change that added the row.
- **Exit condition:** what must be true for the row to go away.
- **Remove by:** a date (YYYY-MM-DD). For a section 7 (d) row, no later than the package's next pin bump here.
- **Added:** YYYY-MM-DD.

Only a step-4 or U3 item that is truly domain may leave "Exit condition" and "Remove by" empty.

Today this repository has no rows.
