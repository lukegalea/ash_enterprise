# Proof spikes for the agent runtime

Small tests that check, against this application's real code, the platform
readings the governed-invocation and durable-agent design depends on. Each
file is one spike. A spike either passes (the reading holds) or asserts the
behaviour actually observed and says, in its `@moduledoc`, what that means
and which fallback the design takes instead.

No spike adds schema. Spikes that need a trigger or an approval subject on a
real platform resource use `AshEnterprise.AgentSpike.Subject`
(`test/support/agent_spike/`), a test-only resource over an existing table
with `migrate? false` in a domain that is never registered. S9 needs a table
of its own: it generates the migration into a temporary directory and runs it
inside each test's sandbox transaction, so nothing is committed. S1 needs no
database and no provider; a fake model transport records every request.

Run them with:

```bash
devenv shell -- mix test test/ash_agent_spike
# S7 against the configured in-zone runtime (synthetic prompt only):
S1_GEN_BASE_URL=… S1_GEN_MODEL=… devenv shell -- mix test --only in_zone_live test/ash_agent_spike
```

| Spike | Question | Result | Consequence |
|---|---|---|---|
| S1 | Can a tool loop resume from recorded tool results, so no effect runs inside it? | Holds, with a correction | After a resume the model's next request equals the in-loop run's: same messages and tool definitions, same OpenAI and Anthropic wire bodies (call ids paired with results, the thinking signature kept through the JSON transcript). Recorded failures and refused approvals arrive as ordinary tool results. Correction: a tool callback cannot see which call it answers (upstream U1), so the runtime appends `Context.tool_result/2` for each pending call and calls `run/2`, which gives the identical request (asserted); recorded-result tools work only by handing out results in pending-call order. |
| S2 | Does the audit log keep only ciphertext of sealed fields, and what happens to a column derived from them? | Holds | Sealed fields are recorded as `encrypted_*` ciphertext only. A derived plaintext column **is** recorded in plaintext (asserted), so the design allows none; a column that must exist is marked `sensitive?` (recorded as nil), and digests are keyed HMACs. |
| S3 | Can an internal-only target and its completion commit in one transaction, with outbound HTTP blocked? | Holds | Effect, audit event and completion commit or roll back together; a retry commits once. A hook that calls out runs before commit inside the enclosing transaction, so a blocked-HTTP contract test catches it. The block covers the integration façade; model calls need their own stub. |
| S4 | Do `optimistic_lock` and a filter on the update survive the audit wrapper, and does a stale write roll back its pre-written event? | Holds | A stale lock or a filter that no longer matches fails with `StaleRecord`, leaves the row as the winner wrote it, and leaves no audit event. Atomic updates on audited rows are refused (asserted). Fencing and budgets are built from these two primitives. |
| S5 | Does a trigger with a calculated `where` work on a platform resource under its default policies, with the tenant taken from the row and a generic action that holds no transaction? | Holds, with a correction | The calculation runs in SQL across tenants as the `:oban` actor; each job runs in its row's tenant, outside a transaction. Correction: a generic-action trigger is **not** re-checked against `where` before it runs, so the action's first write must be a filtered claim (one winner, the loser ends quietly). A trigger needs a scheduler (`scheduler_cron`) to be swept at all. |
| S6 | Does a standalone approval work end to end through the existing doors? | Holds | Runtime-computed candidates, four-eyes exclusion and expiry delegate to the engine's approval change; candidacy reaches the instance-less task; the decision goes through the existing approve action; a trigger applies it (never `on_complete`); a second pending request for the same subject and key is refused and changes nothing. Expiry is a timer job, not a column, and the decider has no principal type, so the applying trigger looks the person up. |
| S7 | Are tool-call ids from the in-zone model server unique within a run? | Holds | The deployed server returns `call_<completion id>_<index>`, unique across completions. The invocation key keeps the step sequence anyway, which stays unique for servers that number calls per turn (asserted). |
| S8 | Is there a maintained Hex package for RFC 8785 (JCS) that passes the RFC's vectors? | Holds, with a caveat | `jcs` 0.2.0 passes the RFC's §3.2.2–§3.2.4 sample, the §3.2.3 sorting vector and every finite Appendix B number (test-only dependency for now). `rfc8785` needs a newer Erlang/OTP than this application runs. Caveat: integers beyond ±2^53 keep all their digits (asserted), so the adopting digest helper must refuse or stringify them. |
| S9 | Does a package fragment with attributes, actions and a state machine compose onto the platform resource with audit and triggers? | Holds, with a constraint | The package's spike fragment (kept in its `test/support`) compiles onto `Platform.Resource` with AshEvents and an ash_oban trigger; the migration generator derives one table with the fragment's and the base's columns; the fenced update records one audit event and a stale holder gets `StaleRecord` with no event; the trigger's claim is audited as the `:oban` actor. Constraint: the base's lifecycle state machine merges with the fragment's and fails to compile, so such a host resource sets `lifecycle?: false`. |
