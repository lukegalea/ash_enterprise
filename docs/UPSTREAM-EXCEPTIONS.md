# Upstream exceptions

Code or UI that stays below its placement step on purpose. The rule is
[ADR 0070](adr/0070-upstream-first-placement.md). No row, no merge.

Add one row per item. A workaround for a dependency bug does not go here. It goes in
[BLEEDING-EDGE.md](BLEEDING-EDGE.md) section 3.

| Path | Step skipped | Reason | Upstream issue or ticket | Owner | Exit condition | Date |
|---|---|---|---|---|---|---|

Columns:

- **Path:** the file or module that is the exception.
- **Step skipped:** the placement step it should have used (1 to 4, or U1 to U3 for UI).
- **Reason:** what was tried and why upstream is wrong or too early. "It was faster" is not a reason.
- **Upstream issue or ticket:** a link. Use "none" only for a step 4 item that is truly domain.
- **Owner:** the person who answers for it.
- **Exit condition:** what must be true for the row to go away. A row with no exit is allowed only for a step 4 item that is truly domain.
- **Date:** YYYY-MM-DD.

Today this host has no rows.
