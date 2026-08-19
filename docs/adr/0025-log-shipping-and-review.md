# ADR 0025 — Logs ship to the customer's SIEM; review is evidence, not a habit

- **Status:** proposed
- **Date:** 2026-08-19

## Context

The audit log is complete, queryable and now verifiable. It also goes nowhere.

That matters for two reasons that are easy to conflate. The first is ours: nobody is watching. Every
SOC 2 engagement asks not whether logs exist but whether they are *reviewed*, and produces the
evidence of review — a rota, an alert that fired, a ticket that closed — as the actual control.
Logs nobody reads are not a control, and there is currently nothing to show.

The second is the customer's. An enterprise buyer running their own SIEM expects to ingest your events
alongside everything else, because their detection rules are theirs and their retention obligation is
theirs. "Log in to our admin panel" is not an answer at that scale.

These want different things. Ours wants aggregation across tenants and alerting we own. Theirs wants
one tenant's stream, in their format, in their system.

## Decision

**Two sinks, and the tenant boundary is the difference between them.**

**To the customer: a per-tenant structured export.** An `Ash.Notifier` on the event log streams events
as structured JSON to a customer-configured destination — one tenant's events, filtered by the same
`organization_id` a read would be. The chain hashes travel with them, so the copy in the customer's
SIEM is verifiable against the original rather than merely similar to it, which is the same reason the
CSV export carries them.

**To us: Grafana LGTM**, as [ADR 0018](0018-grafana-lgtm-observability-backend.md) already chose for
traces and metrics. Audit events are a third stream into the same place, correlated by the correlation
id that already threads every request.

**Alert rules come from the ledger.** The control map already knows which questions bear on CC7.2 and
CC7.3; the rules that produce evidence of monitoring should be derived from the same source rather
than maintained beside it — the argument [ADR 0021](0021-control-mapping-is-generated.md) makes about
documents applies to alerts.

## Consequences

**What this makes easy.** Answering "how do you know?" with a fired alert rather than an intention.
And removing a class of support request: a customer with their own SIEM stops needing us to answer
questions about their own data.

**What it makes hard.** A shipped log is a copy outside the boundary, and copies do not obey the
policy that governed the original. Whoever configures the destination is deciding where a tenant's
audit trail goes, which makes that configuration itself a privileged, audited action — and makes
misconfiguring it a data-egress incident rather than a broken integration.

**Delivery is a real problem, not a detail.** A sink that is down must not lose events and must not
block the write path. Oban with retries, and a documented lag, rather than an in-request HTTP call.

## Does it consume ActorContext?

**Partially, and the shortfall is the whole design.** A SIEM cannot consume `ActorContext`: it has its
own users, its own roles, and no way to evaluate a grant union. Splunk and Elastic both ship RBAC that
would have to be maintained in parallel, and by the rule in
[thesis 6](../manifesto/06-reversibility.md) that disqualifies it from holding cross-tenant data.

So the boundary is drawn at what is sent rather than at who may read it there: **a sink receives one
tenant's events and never a cross-tenant stream.** Authorization inside the SIEM is then the
customer's problem about their own data, which is the only version of this that does not require
mirroring the security model into a system that cannot express it.

## Reversal

Delete the notifier and the destination configuration. Events stop leaving; nothing that already
arrived can be recalled, which is the usual property of shipping data somewhere and worth stating.
Under a day, and the internal Grafana half is independent of the customer-facing half — either can go
without the other.
