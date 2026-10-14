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
| 2026-10-12 | Audit | Registration writes the bcrypt `hashed_password` into the append-only audit log. | Fixed, 8c40d2d (`sensitive?` values are nil in every audit field). One pre-fix row remains in dogfood: the operator's own registration. Remedy per docs/runbooks/audit-sensitive-values.md is a password reset. |
| 2026-10-14 | Runtime | The dogfood Postgres died; the app shut down after it. Cause: systemd stopped the whole herdr-server cgroup, which the app and DB were running in, after an OOM kill. | Fixed: own units |
| 2026-10-14 | Runtime | Host OOM kills. Every BEAM sat at ~2.5 GB before doing work because ERTS sized its fd tables from a ~1.07e9 open-files hard limit. | Fixed, 77194a0 |
| 2026-10-14 | Runtime | An agent's `pkill -f "phx.server"` in another checkout stopped dogfood. | Fixed: the app no longer runs as `mix phx.server`; Restart=always; agents told to kill by PID |
| 2026-10-14 | Runtime | Dogfood now runs as enabled systemd user units `dogfood-pg` and `dogfood`, capped at 2 GB each. The Postgres port moved 5434 → 5435 (devenv picks a free port). | Done |
| 2026-10-14 | Sync | Slack only ever found 16 conversations: with a user token `conversations.list` returns the whole workspace's public channels, and the step stops after 20 pages (`list_truncated=true` every step), so later conversations are never reached. | Fixed, 3fddc1d (`users.conversations`). Live: 155 conversations listed, not truncated; DMs now land (839 DM messages on the first steps). Two channels projected on 10-12, before conversation kinds existed, keep a null kind until their next message. |
| 2026-10-14 | ACP | Deferred low-privilege run: a member with a narrow role could not open an ACP session (a generic action's grant check returned a row filter, which Ash raises on), and approving something policy refuses hung the session. | Fixed, 1b88b34 |
| 2026-10-14 | Policy | A member without a `:global` MorningBrief grant cannot compose their own brief (`compose_today` is a generic action), so the scheduled brief and the compose button refuse them. Today still says "say `compose brief`". | Open: needs a policy decision (e.g. an explicit own-brief rule) |
| 2026-10-14 | ACP | A write the user can't do still raises a permission request before policy refuses it; refused surface writes reply `outcome: "applied"` (ash_acp's schema has no failure outcome). | Open: ash_acp |
| 2026-10-14 | BPMN | A service task that errors or dies mid-job leaves its token `executing`; every retry crashes and the instance never fails. Dogfood has no stuck tokens. | Fix in progress (ash_bpmn) |
| 2026-10-14 | Tooling | The codegen hook ran in an ash_bpmn checkout (it has devenv.nix and mix.exs too) and six checks there reached ~15 GB. | Fixed, 31856ad (matches the app name); ash_bpmn's own nofile cap in progress |
