# AshAgent host behaviours

The package calls these instead of reading your actors, grants or keys. Name your implementations in the
`invocation` section of the resource that includes `AshAgent.Invocation`.

## `AshAgent.ExecutionIdentity`

```elixir
@callback principal_for(actor, context) :: {:ok, principal} | {:error, term}
@callback actor_for(invocation) :: {:ok, actor} | {:error, term}
@callback principal_of(actor) :: {:ok, principal} | :error

# principal:
%{type: :person, id: person_id}
%{type: :automation, id: name, on_behalf_of: person_id | nil, agent: agent_key | nil}
```

1. `principal_for/2` runs when an invocation is requested and names who it will run as. Return an error for an actor
   that may not request work (a request with no principal is refused, not recorded).
2. `actor_for/1` runs at every claim. Build the actor afresh from current grants: authority is what the principal holds
   when the work runs, not what it held when it was asked for. Return an error when the principal no longer has
   authority; the row fails as `:denied` and its target never runs.
3. Never return a more privileged actor than the principal, and never fall back to a system actor.
4. An automation principal acting for a person may do only what both its own grants and that person's allow. Rebuild
   both at every claim and refuse when either has lost the authority (or when the person may no longer start the
   agent). Every field of the principal is part of its identity, so `invoke` never hands one person's row to another.
5. Return a plain atom as the reason (`:inactive`, `:start_grant_revoked`): the row records it as
   `"no_authority: <reason>"`. Any other reason is recorded as `"no_authority"`.
6. `principal_of/1` is the inverse of `actor_for/1`: given an actor `actor_for/1` built, it names the principal that
   actor runs as, read from the actor alone and without a query. Return `:error` for any other actor (a system actor,
   a request's actor that is not one you built). `AshAgent.Validations.Governed` uses it to check that a governed
   action runs as its invocation's principal, so it must tell an automation acting for a person from that person.
7. The row's `delegation` column holds the principal in RFC 8693's `act` shape
   (`AshAgent.ExecutionIdentity.delegation/1`), for readers outside the package. It is informational.

## `AshAgent.FailureClass` (a protocol)

```elixir
defimpl AshAgent.FailureClass, for: MyClinic.Gateway.Error do
  def classify(%{reason: :rate_limited}), do: {:transient, "rate_limited"}
  def classify(%{reason: :timeout}), do: {:indeterminate, "timeout"}
  def classify(%{reason: reason}), do: {:permanent, to_string(reason)}
end
```

1. Implement it for each error type of yours that a target can return. Unimplemented, an error is classified by the
   Ash error it is wrapped in: forbidden is `:denied`, invalid is `:rejected`, anything else `:permanent`.
2. Return `:transient` only when the call certainly did not take effect (refused before it was processed, such as a
   rate limit). A timeout or a dropped connection after sending is `:indeterminate`: the effect may have happened.
3. The code is stored in `error_code` and shown to operators; keep it short and stable, never a message with data in
   it.

## `AshAgent.DigestKey`

```elixir
@callback digest_key(invocation) :: {:ok, binary} | {:error, term}
```

1. Return the HMAC key for the row's `args_digest`. It is called with the stored row, or with the row about to be
   inserted after every change of the request has run, so a column your own change sets on `request` is there.
2. If you encrypt content per subject, derive the key from that subject's key, so destroying the subject's key also
   makes the digest unrecomputable.
3. The same row must always give the same key: `invoke` compares a new request's digest with the stored one.
