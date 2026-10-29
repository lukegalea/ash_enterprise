# AshAgent host behaviours

The package calls these instead of reading your actors, grants or keys. Name your implementations in the
`invocation` section of the resource that includes `AshAgent.Invocation`.

## `AshAgent.ExecutionIdentity`

```elixir
@callback principal_for(actor, context) :: {:ok, principal} | {:error, term}
@callback actor_for(invocation) :: {:ok, actor} | {:error, term}

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
6. The row's `delegation` column holds the principal in RFC 8693's `act` shape
   (`AshAgent.ExecutionIdentity.delegation/1`), for readers outside the package. It is informational.

## `AshAgent.DigestKey`

```elixir
@callback digest_key(invocation) :: {:ok, binary} | {:error, term}
```

1. Return the HMAC key for the row's `args_digest`. It is called with the stored row, or with the row about to be
   inserted after every change of the request has run, so a column your own change sets on `request` is there.
2. If you encrypt content per subject, derive the key from that subject's key, so destroying the subject's key also
   makes the digest unrecomputable.
3. The same row must always give the same key: `invoke` compares a new request's digest with the stored one.
