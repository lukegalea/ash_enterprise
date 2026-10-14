# Dogfood log (E6, PROD-7)

The two-week daily-driver log from [the program plan](productivity-os-dogfood.md): what broke, what was
missing and what got in the way while the operator ran their day on the dogfood instance. At the end of the
window each open entry is triaged into a PROD ticket or closed.

**Window:** 2026-10-12, when the first live syncs ran, to 2026-10-26.

**Rules for entries:**
- One line of what happened, then the fix or the ticket.
- Never the content of a message, event or conversation, and never a person's name. The instance holds
  real mail and VendorPM Slack; counts, ids and timestamps are fine.

| Date | Area | What happened | Status |
|---|---|---|---|
| 2026-10-12 | Setup | The dev app would not start: `AshEvidence.Repo` had no dev config. | Fixed, c24f79a |
| 2026-10-12 | Setup | `mix ash_enterprise.seed` cannot seed the tenant half without the endpoint running (the confirmation sender needs it). Worked around with `Seeder.seed_tenant/1`. | Open |
| 2026-10-12 | Sync | First live steps: Calendar landed 1,893 events; Slack landed 1,359 messages in 16 conversations; Gmail landed ~100 messages, then Google returned 429. The step snoozed 60 s and resumed from the saved page, as designed. | Working; watch Gmail backfill pace |
| 2026-10-12 | Sync | The dev SQL debug log echoes query parameters, which include people's names and emails in plaintext. The sync task's "counts only" promise holds for its own output, not for the logger. | Fixed: `LOG_LEVEL=info` (config/runtime.exs) on the dogfood unit. Logs written before 2026-10-14 still hold them (mode 600). |
| 2026-10-12 | Audit | Registration writes the bcrypt `hashed_password` into the append-only audit log. | Fix in progress |
| 2026-10-14 | Runtime | The dogfood Postgres died; the app shut down after it. Cause: systemd stopped the whole herdr-server cgroup, which the app and DB were running in, after an OOM kill. | Fixed: own units |
| 2026-10-14 | Runtime | Host OOM kills. Every BEAM sat at ~2.5 GB before doing work because ERTS sized its fd tables from a ~1.07e9 open-files hard limit. | Fixed, 77194a0 |
| 2026-10-14 | Runtime | An agent's `pkill -f "phx.server"` in another checkout stopped dogfood. | Fixed: the app no longer runs as `mix phx.server`; Restart=always; agents told to kill by PID |
| 2026-10-14 | Runtime | Dogfood now runs as enabled systemd user units `dogfood-pg` and `dogfood`, capped at 2 GB each. The Postgres port moved 5434 → 5435 (devenv picks a free port). | Done |
| 2026-10-14 | Sync | Slack only ever found 16 conversations: with a user token `conversations.list` returns the whole workspace's public channels, and the step stops after 20 pages (`list_truncated=true` every step), so later conversations are never reached. | Fix in progress: list via `users.conversations` |
