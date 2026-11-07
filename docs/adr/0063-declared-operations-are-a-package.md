# ADR 0063 — Declared provider operations are a package

- **Status:** proposed (2026-11-06; the credential registry is the built reference, Nango's operations are unchanged)
- **Date:** 2026-11-06
- **Related:** ADR 0011 (Nango as the provider edge), 0012 (lineage fills the holes), 0026 and 0042 (leaving the zone is a
  disclosure), 0055 (governed invocations), 0056 (the runtime is a package the host instantiates), 0059 (machinery-only actions)

## Context

ADR 0011 built the first vertical of the provider edge in this repository: a Spark DSL where each declared
`operation` is one generic Ash action, one transport module speaks HTTP, no action takes a credential, and there is
no integration log. It said "exercise once, then promote". Three providers exercised it, so the shape is now known.

The same shape is needed for providers that are not reached through Nango: a provider with a deployment credential
rather than an OAuth connection, with an HMAC-signed webhook. The template already had a place for one. The credential
registry (`AshEnterprise.Credentialing.Registry`) was an ETS stub whose moduledoc said "a connector to a real registry
replaces this module", and `Credential.activate_credential` already declared, through `AshAgent.Effects`, that it is not
idempotent, reaches outside the application, and is reconciled through `lookup_activation`. A lost answer from a call that
may have happened is the problem `ash_operations` exists to make explicit (`:ambiguous` and `reconcile_with`).

## Decision

1. **Providers this template reaches directly are declared with [`ash_operations`](https://github.com/lukegalea/ash_operations).**
   The package promotes the in-repo DSL's idea: one generic action and code interface per operation, a vendored OpenAPI
   document pinned by sha-256 and verified at compile time, one `Req` transport per provider, one retry table, typed errors,
   and a provider-neutral signed webhook ingress.
2. **The credential registry is the reference provider.** `AshEnterprise.Credentialing.RegistryApi` declares
   `activate`, `list_activations` and `get_activation` against a synthetic spec
   (`priv/vendor/credential_registry/`). With no `CREDENTIAL_REGISTRY_URL` an in-process fake serves the same spec over the
   old ETS state, so the template runs offline exactly as before, with the real transport, retry and classification
   exercised on the way. A governed, four-eyes act now reaches an HTTP API, and a lost answer is reconciled, never re-sent.
3. **Nobody calls the registry past the approval.** `RegistryApi` carries no role grant. Its one additive grant,
   `Security.Checks.GovernedCall`, admits a call that carries the invocation governing it. Not a `forbid_if`, and no query.
4. **Leaving the zone is decided on the host's zone model.** `activate` sends a licence number, so it `discloses?`;
   `RegistryDisclosureGate` reads the credential that justifies the send and asks `Zones.ResidencyPolicy`. A refusal
   sends nothing, and the invocation records it as `denied`.
5. **Webhooks are nudges.** `AshOperations.Webhook.Ingress` is mounted in the endpoint, ahead of `Plug.Parsers` and matching
   only `POST /webhooks/:provider`, because a signature covers the exact bytes. A delivery
   (`Integration.Operations.Delivery`) records an activation id and nothing else; its follow-up reads the registry by that
   id, learns the tenant from the registry's own answer, and makes the waiting reconcile run sooner. It decides nothing:
   the reconcile asks the registry again.
6. **One host impl classifies every operation failure for an invocation.** `AshAgent.FailureClass` for
   `AshOperations.Error`: `:ambiguous` is indeterminate, `:disclosure_refused` is denied, rate limits, timeouts, server
   errors and transport failures are transient, credentials and configuration are permanent.

### Who owns which test

This is the rule ADR 0056's package boundary implies, recorded here for this package:

- **The `ash_operations` suite owns** the retry table, spec pinning, signature verification, the ingress's status codes and
  telemetry hygiene.
- **The platform battery owns** the seams with `ash_agent`, `ash_bpmn`, `ash_decisions`, `ash_events` and
  `ash_open_lineage`, run on dependency bumps only (`mix platform_battery`).
- **Host tests own wiring**: mount order, credential resolution, the gate on the zones model, the `FailureClass` mapping,
  the grant, the metrics this host declares.

### Convergence with Nango

The in-repo `Integration.Nango.Operations` DSL stays: Google Calendar, Gmail, Slack and Sheets, with OAuth through Nango
and the connection derived from the actor's `LinkedAccount`. `ash_operations` sits **beside** it. Both satisfy the same
invariants: one transport per provider, no credential or connection argument, the generated generic action is the call path,
and there is no integration log.

They cannot merge yet, for one reason: `AshOperations.Http.config/0` takes no arguments, and the generated action passes the
transport no actor or tenant, so a credential can only be per deployment. Nango's connection id comes from the actor. When the
package hands call context to the transport, `Nango.Proxy` becomes an `AshOperations.Http` transport and the in-repo DSL is
retired in favour of `operations do transport Nango.Transport ... end`. Until then there are two DSLs, on purpose.

### Consequences worth knowing

- **A non-idempotent call that may have been sent is `:ambiguous`**: 5xx responses, timeouts and other transport
  failures after a send are never re-sent, and leave the invocation `outcome_unknown` to be reconciled. Connection-level
  failures that prove nothing was sent (`:econnrefused`, `:nxdomain`, `:ehostunreach`, `:enetunreach`, `:eaddrnotavail`)
  are retried and end as `:transport`, which the host classifies as transient and defers.
- **The generated actions are not writes**, so neither the event log nor lineage records an operation call. The record of an
  outbound act is the governed invocation and the subject's own update, both platform resources. The remote dataset is a hole
  in lineage, filled by one explicit `AshOpenLineage` emit (ADR 0012), structural names only.
- **The registry key is a deployment secret** of database-password class, like the Nango secret key.

### Reversal

Delete `credentialing/registry_api*`, `credentialing/registry/fake_provider.ex`, `integration/operations/`,
`ProviderWebhooks` in the endpoint and the dependency, and restore the `Registry` calls in `Changes.ActivateInRegistry`
and `Actions.LookupActivation`. About an afternoon.
