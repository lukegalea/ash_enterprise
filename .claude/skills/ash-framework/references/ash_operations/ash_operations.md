# Rules for working with AshOperations

## Understanding AshOperations

AshOperations is a Spark extension for Ash resources. An `operations do ... end` section declares
a provider's HTTP operations; each becomes one generic action (returning the decoded body as a map)
and a code interface function of the same name. Read the module docs of `AshOperations` before
declaring anything.

## Declaring operations

- Every operation needs a method, a path and its params. `{placeholder}` path segments need an
  `in: :path` param, and the reverse.
- `in: :body` params need `request :json`; `in: :part` params need `request :multipart`; a `get`
  sends no body.
- Declare `param :x, :type, as: "providerName"` when the wire name differs from the argument name.
- Use `response :binary` for downloads and `response :none` when the body is not wanted.
- Do not declare a param named like a credential (key, token, secret, authorization, bearer).
  The compiler refuses it. The transport owns the credential.

## Spec pinning

- Vendor the provider's OpenAPI 3.x JSON, set `spec` and `spec_sha256`. After a provider change,
  review the diff, re-check the declarations, then update the pin. Never update the pin alone.
- Without a published spec, give every operation `documented_at` with the documentation URL.

## Idempotency and ambiguity

- `get`, `put` and `delete` default to idempotent; `post` and `patch` do not.
- A non-idempotent operation must set `reconcile_with :some_list_read` or `reconcile_with :none`.
- On `{:error, %AshOperations.Error{reason: :ambiguous}}`, never re-send. Wait for the provider's
  settle window, then call `AshOperations.Reconcile.find/5`.
- On `:rate_limited`, use `retry_after_ms` to schedule a later attempt instead of sleeping.

## Transports

- Write one transport per provider with `use AshOperations.Http`. Implement `config/0`; override
  `classify/1` to read the provider's error code and request id. Never copy a message or body into
  the classification.
- In tests, pass `req_options: [plug: {Req.Test, MyTransport}]` and a `sleep:` function.

## Disclosure

- Mark operations that send classified data `discloses? true` and set `disclosure_gate`. The action
  then requires `disclosure_ref`; the gate decides from your own records, never from the payload.

## Webhooks

- A webhook is a nudge. Implement `AshOperations.Webhook.Provider`: verify the exact signed bytes,
  return a redelivery-stable dedup key, enqueue ids only. Never act on payload values.
