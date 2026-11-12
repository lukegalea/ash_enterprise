# ADR 0066 — Every way in shares one standard

- **Status:** accepted (2026-11-09)
- **Date:** 2026-11-09
- **Related:** ADR 0043 (automation principals), 0052 (self-service), 0055 (governed invocations), 0059 (human-only actions)

## Context

Native sign-in had four gaps a host inherited. A deactivated user could still sign in, and their session and bearer
tokens kept working until the library's 14-day default ran out. The session cookie and LiveView salts were string
literals in a public repository. Nothing limited repeated password guesses. A role grant could not end, and
impersonation recorded who acted but not whether it was allowed.

## Decision

1. **Deactivation ends access at every door.** `Preparations.ActiveOnly` is on each read that finds a user for
   authentication: password and token sign-in, `get_by_subject` (session and bearer tokens), the lookup behind a
   password reset and API key sign-in. `deactivate` revokes the user's stored tokens in the same transaction
   (`Changes.RevokeTokensOnDeactivation`), so reactivating does not revive an old token.
2. **A session token lives 8 hours**, set explicitly in `Accounts.TokenPolicy`; a host overrides it with
   `config :ash_enterprise, :token_lifetime`. The DSL is compiled, so the value is read when `User` compiles.
3. **Both signing salts come from the environment in production** (`SESSION_SIGNING_SALT`, `LIVE_VIEW_SIGNING_SALT`),
   and `config/runtime.exs` stops the boot when either is missing, short, equal to the other, or one of the built-in dev/test salts. Dev and test boot with those built-ins and need no setup.
4. **Lockout is a Postgres row**, advanced by one atomic upsert (`SignInLockout.record_failure`), so the count holds
   across processes and nodes. It is keyed by a digest of the normalized email and counts unregistered addresses the
   same way. A store that cannot be read refuses the sign-in.
5. **Bearer keys expire and inherit their owner's lifecycle.** `Accounts.ApiKey` requires `expires_at` within a
   configurable maximum; `User.valid_api_keys` counts a key only while its owner is `:active`. `Plugs.LoadFromBearer`
   sends `aek_` keys to the API key strategy and answers an unusable one with 401.
6. **Role grants may carry `valid_until`** (`UserRole`, `TeamRole`). `ActorContext.build/2` counts a grant while
   `valid_until` is unset or later than now: at the instant itself it is gone.
7. **Break-glass impersonation is a row.** `Security.BreakGlassSession` records operator, subject, reason, approver and
   expiry. `open` is only a request. The named approver must run `approve` themselves, as a separate act by a different,
   active person, and only that stamps `approved_at`; `Impersonation.break_glass/3` returns an impersonating actor only
   while a session is approved, active and unexpired. This is a state on the session (requested, then approved) rather
   than a governed invocation (ADR 0055): the approval is one fact about one row, the audit trail already records both
   writes, and nothing else needs the invocation machinery. An impersonating actor can neither open nor approve a
   session: the person at the keyboard is the operator behind it, so acting as the named approver is not approval.

## Consequences

- Unknown, missing, expired, stale or malformed inputs are refused at each of these; none is treated as a pass.
- `Platform.Resource` gains `authentication_plumbing?` for resources the sign-in machinery itself reads and writes.
- Other readers of `UserRole` that decide who counts as an administrator (`Execution.Approval`, and
  `Execution.Authority` for the approval postures) have not been taught `valid_until` yet.
- The lockout is per identity, not per source address; a network-level limit stays with the edge.

## Reversal

Each piece stands alone. The lockout moves to an edge rate limiter by removing `Preparations.SignInLockout` from
`sign_in_with_password`. API keys go by dropping the `api_key` strategy and `LoadFromBearer`. The salts return to
compile-time values only by editing `Endpoint.session_options/0` and `runtime.exs`, which this ADR advises against.
