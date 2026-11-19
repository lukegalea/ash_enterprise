# Runbook: outbound webhooks

Written 2026-11-17, against [ADR 0075](../adr/0075-outbound-webhooks-are-a-declared-operation.md).
Code: `AshEnterprise.Integration.Outbound.Endpoint` and `Delivery` (the records),
`Outbound.Receiver` (the declared operation), `Outbound.Transport`, `Outbound.Egress` and
`Outbound.DisclosureGate` (how a send is made and refused), `Outbound.Catalogue` (what can be
subscribed to). Contract: `priv/webhooks/outbound.openapi.json`. Tests:
`test/ash_enterprise/integration/outbound/*_test.exs`.

## What a receiver gets

One `POST` per event, to the endpoint's registered URL, with `content-type: application/cloudevents+json`:

```json
{
  "specversion": "1.0",
  "id": "0193b5a4-…",
  "source": "/organizations/<organization id>",
  "type": "ash_enterprise.team.create",
  "subject": "<the record's id>",
  "time": "2026-11-17T09:30:00.000000Z",
  "datacontenttype": "application/json",
  "data": {"id": "<the record's id>"}
}
```

The event names the record and carries nothing else of it. The receiver reads the record through the API with
its own key, and sees only what that key's grants allow.

Three headers, per [Standard Webhooks](https://www.standardwebhooks.com/) v1:

| Header | Value |
|---|---|
| `webhook-id` | the event id (equal to the body's `id`); the same on every attempt and every redelivery |
| `webhook-timestamp` | when this attempt was signed, Unix seconds |
| `webhook-signature` | `v1,` then the base64 HMAC-SHA256 of `"<webhook-id>.<webhook-timestamp>.<raw body>"`, keyed by the base64-decoded part of the endpoint's `whsec_` secret |

Delivery is **at least once**: deduplicate on `webhook-id`. Any 2xx acknowledges. Anything else, or no answer
within 10 seconds, is retried after 1 minute, 5 minutes, 30 minutes, 2 hours and 12 hours; after the sixth
attempt the delivery is dead. Redirects are not followed.

## Verifying a delivery

Verify over the **raw body bytes**, before parsing them, and compare in constant time. Reject a timestamp more
than five minutes from your clock.

```python
import base64, hashlib, hmac, time

def verify(secret: str, headers: dict, body: bytes) -> bool:
    key = base64.b64decode(secret.removeprefix("whsec_"))
    msg_id, ts = headers["webhook-id"], headers["webhook-timestamp"]
    if abs(time.time() - int(ts)) > 300:
        return False
    expected = base64.b64encode(
        hmac.new(key, f"{msg_id}.{ts}.".encode() + body, hashlib.sha256).digest()
    ).decode()
    return any(
        hmac.compare_digest(expected, sig.removeprefix("v1,"))
        for sig in headers["webhook-signature"].split(" ")
        if sig.startswith("v1,")
    )
```

The Standard Webhooks libraries (`standardwebhooks` for Python, JavaScript, Go and others) verify the same
headers and can be used instead.

## Registering an endpoint

Registration is a person's act (`human_only`): an automation principal is refused whatever its grants. The web
surface lists endpoints and deliveries; registering and rotating are code-interface calls for now, because the
secret is shown once and the surface library has no way to show a value once.

```elixir
endpoint =
  AshEnterprise.Integration.register_webhook_endpoint!(
    %{url: "https://hooks.example.com/ae", event_types: ["ash_enterprise.team.create"]},
    actor: person, tenant: organization_id
  )

endpoint.__metadata__.signing_secret   # "whsec_…": hand it to the receiver now; it is not shown again
```

`AshEnterprise.Integration.Outbound.Catalogue.types/0` lists what can be subscribed to: the create, update and
destroy of every audited resource with a public API type. Anything else is refused at registration.

A new endpoint starts at the tenant's current position in its audit log: it is never sent what happened before
it was registered.

## Rotating the secret

`AshEnterprise.Integration.rotate_webhook_secret!(endpoint, actor: person, tenant: organization_id)` returns the
new secret once, in the same `signing_secret` metadata, and every send from then on is signed with it. There is no
overlap: a delivery signed with the old secret and retried after the rotation is re-signed with the new one, so
update the receiver promptly. The old secret is not kept.

## When an endpoint stops receiving

Look at the endpoint's `status` and `status_reason` on the webhook endpoints surface:

| `status_reason` | What happened | What to do |
|---|---|---|
| `disabled` | a person disabled it | `enable` it |
| `repeated_dead_letters` | three deliveries in a row were dead-lettered | fix the receiver, then `enable`; redeliver the dead deliveries from the deliveries surface |
| `egress_private_address`, `egress_scheme`, `egress_port`, `egress_host`, `egress_userinfo` | the URL resolved to a non-public address, or is not https on 443 | the URL cannot be used; register a new endpoint at a public URL |
| `cursor_behind_retention` | the endpoint was off for longer than the audit log's hot window (90 days) | `enable` restarts it at the current position; read the gap from the audit export |

A delivery's `last_reason` is a short code, never a response body: an `AshOperations` reason (`server`,
`timeout`, `transport`, `bad_request`, …) or a refusal code (`endpoint_inactive`, `residency_denied`,
`secret_shredded`, `egress_*`). A `refused` delivery sent nothing and is not retried; `redeliver` sends it again
from the first attempt.

## Erasure

Each endpoint's secret is sealed under its own erasure scope (`:connection`, `outbound_endpoint:<id>`).
Shredding that scope leaves the endpoint unable to sign: every later delivery is refused with `secret_shredded`,
and nothing is sent. Register a new endpoint to start again.

## Operating

- The fan-out runs every minute, once per organization with an active endpoint, on the `webhooks` Oban queue;
  the `:deliver` trigger sends due deliveries on the same queue.
- The egress guard resolves the host on every send and connects to the address it vetted, keeping the name for
  `Host`, SNI and certificate verification. A deployment's own internal addresses are refused by design, so an
  instance cannot deliver to itself or to anything on its private network.
- `config :ash_enterprise, AshEnterprise.Integration.Outbound.Transport, req_options: [...]` adds Req options to
  every send (tests use it for a `Req.Test` plug). `config :ash_enterprise, AshEnterprise.Integration.Outbound.Egress,
  resolver: fun` replaces the resolver (tests only).
- Each distinct endpoint gets its own connection pool, because the vetted address is a connect option. That is
  fine at the volumes a tenant's endpoints produce; a per-tenant cap is not decided (ADR 0075, "Not decided here").

## Re-pinning the contract

The receiver contract is pinned by sha-256 in `Outbound.Receiver`. After editing
`priv/webhooks/outbound.openapi.json`, compute the new hash (`sha256sum priv/webhooks/outbound.openapi.json`),
put it in `spec_sha256`, and say in the commit what changed for receivers: the file is what they build against.
