# ADR 0075 — Outbound webhooks are a declared operation: a signed CloudEvent nudge per audited write

- **Status:** accepted (2026-11-17), built
- **Date:** 2026-11-17

## Context

A tenant that integrates with this platform wants to hear about changes as they happen instead of polling the API.
The usual answer is an outbound webhook: the tenant registers a URL, and the platform POSTs to it when something
the tenant cares about changes.

Every outbound call here is already a declared operation (ADR 0063, `ash_operations`): a generic action whose
request shape is pinned to a spec, sent by a transport the host writes, behind a disclosure gate that can refuse,
with one retry table and typed errors. A webhook is an outbound call like any other, with three differences: the
destination is chosen per call (each endpoint has its own URL), each request must be signed with that endpoint's
own secret over the exact bytes sent, and the destination is a URL a tenant typed, so it is attacker-chosen.

The audit log (`Audit.EventLog`) already records every write to an audited resource, in commit order within a
tenant's chain, with the actor, the action and the record id. It is the one place that knows "what changed".

## Decision

**A tenant's webhook is a declared operation, fanned out from the tenant's own audit log, carrying a thin
CloudEvent and signed per Standard Webhooks v1.**

1. **The library carries the call.** `ash_operations` gains, additively: the call's actor, tenant and
   `in: :context` parameters in the transport's `meta`; a `config/1` callback, so a transport can choose the
   destination per call and refuse with a code; a `sign/3` callback, called once per call with the exact body
   bytes sent; JSON bodies encoded by the library to bytes, so retries resend the same signed bytes; and a
   `redirect` config key (default `true`, unchanged). A context parameter never reaches the wire.
2. **The receiver is `Integration.Outbound.Receiver`**, one operation, `deliver`, pinned to
   `priv/webhooks/outbound.openapi.json`, which is also the contract a receiver reads.
3. **The payload is a nudge.** A CloudEvents 1.0 structured event (`application/cloudevents+json`) with `id` (the
   audit event id), `type` (`ash_enterprise.<resource>.<create|update|destroy>`), `source`
   (`/organizations/<id>`), `subject` and `data.id` (the record id), and `time`. No attribute of the record is sent:
   the receiver reads it through the API with its own key, under its own grants. A nudge cannot leak a field a
   grant would hide, and needs no per-type schema.
4. **The catalogue is derived.** Every audited resource exposed through the API (`api_type`), outside the
   integration, process and BPMN domains, contributes its create, update and destroy (`Outbound.Catalogue`). An
   endpoint subscribes to a list of those types; anything else is refused at registration. The integration
   domain is excluded so no delivery is ever the event that causes another.
5. **Fan-out reads the log, never hooks the write.** A per-tenant scheduled action reads the tenant's chain
   high-water mark first, then the events after each endpoint's cursor up to it, and creates one
   `Outbound.Delivery` per matching event (idempotent on `(endpoint, event)`). Reading the mark first means a
   transaction that commits during the read is picked up next time, never skipped. A new endpoint's cursor starts
   at the mark, so it is never sent history. A cursor older than the retained hot window marks the endpoint
   `failing` (`cursor_behind_retention`) rather than skipping silently; re-enabling restarts it at the mark.
6. **Delivery retries on a fixed schedule.** The first attempt, then retries after 1 minute, 5 minutes, 30 minutes,
   2 hours and 12 hours; after the sixth attempt the delivery is dead. Three dead deliveries in a row mark the
   endpoint `failing` (`repeated_dead_letters`). A person re-enables it, which is audited. A delivery is
   redelivered with the same `webhook-id`, so a receiver that deduplicates sees it once.
7. **The guard is the host's.** The egress guard (`Outbound.Egress`) allows https on port 443 only, refuses user
   information, and refuses a destination if any address it resolves to is not public unicast (private, loopback,
   link-local including the metadata address, CGNAT, documentation, multicast, IPv4-mapped, 6to4, NAT64, ULA).
   The connection is made to the vetted address, with the name kept for Host, SNI and certificate verification, so
   a second resolution cannot rebind it. Redirects are not followed. A literal private address is refused at
   registration too.
8. **The disclosure gate checks the tenant's own registration.** The endpoint must be the calling tenant's, and
   active, and the residency policy must allow the new class `:tenant_designated`: a destination the tenant
   registered itself is allowed for that tenant. The registration is the recorded authorization.
9. **The secret is crypto-shreddable.** Each endpoint has its own `whsec_` secret, sealed under an erasure scope
   of its own (`:connection`, `outbound_endpoint:<id>`). It is returned once, as the result metadata of
   `register` and `rotate_secret`, and recorded as nil in the audit log. Shredding the scope leaves the endpoint
   unable to sign, so nothing more is sent.
10. **Registration is a person's act.** `register`, `update`, `rotate_secret` and `enable` are human-only; an
    automation principal is refused whatever its grants. Fan-out and delivery are platform machinery.

## Consequences

- A receiver gets a stable, verifiable, at-least-once stream of "this record changed", and reads the record with
  its own key. It must deduplicate on `webhook-id`.
- Nothing about a record leaves the platform in a webhook body. A tenant that wants fields reads them through the
  API, where field and row grants apply.
- Fan-out costs one indexed read per tenant with active endpoints per minute, and writes nothing when nothing
  changed. The fan-out update is not audited (it would raise the mark it reads).
- Deliveries are not audited and not archived: they hold no payload, only the event id, type, record id, state,
  attempts and the receiver's last status and a short reason.
- The web surfaces list endpoints and deliveries and offer disable, enable and redeliver. Registering and rotating
  are code-interface acts for now, because the surface library has no way to show a secret once.

## Not decided here

- Per-tenant rate limits and a delivery concurrency cap beyond the queue's.
- Whether `redirect: false` becomes the library's default in a breaking release.
- Fat payloads (record attributes in `data`), which would need per-type schemas and field-grant filtering.
