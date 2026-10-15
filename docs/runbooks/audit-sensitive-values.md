# Runbook: sensitive values in audit rows written before 2026-10-14

Since 2026-10-14, every audit event passes through `AshEnterprise.Audit.Changes.RedactSensitive`, so a
`sensitive?` attribute or argument is written as `null` in `data`, `changed_attributes` and `metadata`. The key
stays, so the row still shows that the value changed. The exception is `ash_cloak`'s `encrypted_*` ciphertext, which
ADR 0024 keeps on purpose.

Before that date, ash_events recorded `changed_attributes` without checking `sensitive?`. So **any row written by
registration (`register_with_password`), `change_password` or `reset_password_with_token` may contain the user's
bcrypt hash** in `changed_attributes->'hashed_password'`. This was observed in a dev database on 2026-10-12.

These rows cannot be fixed in place, and should not be. `audit_events` is append-only (a trigger refuses `UPDATE`
and `DELETE`) and hash-chained (ADR 0020). Rewriting a row breaks the chain for every later row in that tenant.

## Find them (read-only)

```sql
SELECT sequence, id, occurred_at, organization_id, resource, action, record_id
FROM audit_events
WHERE changed_attributes->>'hashed_password' IS NOT NULL
ORDER BY sequence;
```

`record_id` is the user's id. Registrations have no tenant, so most rows sit in the `NULL`-tenant chain.

The same leak applied to any other `sensitive?` attribute that an action set through a change rather than as an
input. To check a resource and action, list the names that are now redacted, then query each one the same way:

```elixir
AshEnterprise.Audit.Changes.RedactSensitive.redacted_names(AshEnterprise.Accounts.User, :register_with_password)
```

## What to do about them

- Treat a found hash as exposed to anyone who can read the audit log. Reading it already needs a global read grant
  on `AshEnterprise.Audit.EventLog`, so check who has held that grant.
- The remedy is to make the hash stale, not to remove it: have the affected users reset their passwords. A bcrypt
  hash of a password nobody uses any more is worth nothing.
- Do not drop the triggers or edit rows. `mix ash_enterprise.audit.verify` would report the edit, and an edited log
  is worse evidence than a log with a known, documented defect.
