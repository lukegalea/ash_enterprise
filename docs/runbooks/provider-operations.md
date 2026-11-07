# Runbook: the credential registry connector and its webhook

Written 2026-11-06, against [ADR 0063](../adr/0063-declared-operations-are-a-package.md).
Code: `AshEnterprise.Credentialing.RegistryApi` (the declared operations) and its `Transport`,
`AshEnterpriseWeb.Plugs.ProviderWebhooks` (the route), `AshEnterprise.Credentialing.RegistryWebhook` and
`AshEnterprise.Integration.Operations.Delivery` (the nudge and its follow-up). Tests:
`test/ash_enterprise/credentialing/registry_*_test.exs`, `test/ash_enterprise_web/provider_webhooks_test.exs`,
`test/ash_enterprise/integration/operations_*_test.exs`.

## Configuration

| Variable | What it does |
|---|---|
| `CREDENTIAL_REGISTRY_URL` | The registry's base URL. Unset, an in-process fake answers (dev, demo, test) and nothing leaves the node. |
| `CREDENTIAL_REGISTRY_API_KEY` | The bearer key, read on every call. A URL with no key is "not configured": calls fail with `not_configured` before anything is sent. A secret of the same class as the database password. |
| `CREDENTIAL_REGISTRY_RESIDENCY` | `in_cluster` or `sub_processor` (the default). A sub-processor is refused for a tenant that has not recorded an opt-in, and for everyone under `REQUIRE_IN_ZONE_MODELS`. |
| `CREDENTIAL_REGISTRY_WEBHOOK_SECRETS` | Comma-separated HMAC secrets for the webhook route. |

## Rotating a webhook secret

The route accepts a signature made with **any** configured secret, so rotation has no gap:

1. Agree a new secret with the registry and add it to `CREDENTIAL_REGISTRY_WEBHOOK_SECRETS` beside the old one
   (`old,new`). Restart or redeploy; the value is read from the application environment at runtime.
2. Have the registry sign with the new secret.
3. Once no delivery has arrived signed with the old one, remove it.

Rotating the API key is the same without the overlap: set `CREDENTIAL_REGISTRY_API_KEY` and redeploy. Nothing else reads it.

## Re-pinning the vendored spec

`priv/vendor/credential_registry/openapi.json` is pinned by `spec_sha256` in `RegistryApi`, so a change to it fails
compilation until the pin moves. Never move the pin alone:

1. Replace the file. Read the diff against the operations declared in `registry_api.ex`.
2. Re-check each declaration: method, path, parameters, which calls are idempotent, which are reconciled.
3. Update `spec_sha256` (`sha256sum priv/vendor/credential_registry/openapi.json`) and the operations together.

The file in this repository is synthetic. A real registry's own published document replaces it the same way.

## What a status from the webhook route means

The route is `POST /webhooks/credential-registry`. Responses have empty bodies, and nothing is logged.

| Status | Meaning | What to do |
|---|---|---|
| 204 | Recorded, a duplicate redelivery, or ignored. | Nothing. |
| 400 | Not a JSON object, no `x-registry-delivery` header, or no id-shaped `activationId`. | The sender is wrong. |
| 401 | Bad or stale signature (more than five minutes old). | Check the secret, and the sender's clock. |
| 404 | An unknown provider segment. | The URL is wrong. |
| 413 | The body is over 16 KiB. | The sender is wrong. |
| 429 | Over 300 deliveries a minute from one address. | Back off. |
| 503 | **No webhook secret is configured**, the delivery could not be recorded, or the handler raised. | Set `CREDENTIAL_REGISTRY_WEBHOOK_SECRETS` first. The sender retries a 503, so nothing is lost. |

`mix phx.routes` does not list the route: it is in the endpoint, ahead of `Plug.Parsers`, so the signature can cover the
exact bytes.

## A webhook never settles anything

A delivery is a nudge. Its follow-up reads the registry by the delivery's activation id and makes the reconcile of any
waiting activation run sooner. The reconcile asks the registry again, and only that answer settles an invocation. A forged
delivery can cost one read; it cannot change an outcome, and the tenant is never taken from the payload.

An activation left `outcome_unknown` is reconciled through the registry's list, never re-sent. If it stays unknown, the
invocation waits for a person (the invocation's resolution task).
