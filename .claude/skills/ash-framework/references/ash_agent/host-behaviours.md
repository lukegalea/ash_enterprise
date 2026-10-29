# AshAgent host behaviours

The package calls these instead of reading your actors, grants or keys. Name your implementations in the
`invocation` section of the resource that includes `AshAgent.Invocation`.

## `AshAgent.ExecutionIdentity`

```elixir
@callback principal_for(actor, context) :: {:ok, %{type: :person | :automation, id: String.t()}} | {:error, term}
@callback actor_for(invocation) :: {:ok, actor} | {:error, term}
```

1. `principal_for/2` runs when an invocation is requested and names who it will run as. Return an error for an actor
   that may not request work (a request with no principal is refused, not recorded).
2. `actor_for/1` runs at every claim. Build the actor afresh from current grants: authority is what the principal holds
   when the work runs, not what it held when it was asked for. Return an error when the principal no longer has
   authority; the row fails as `:denied` and its target never runs.
3. Never return a more privileged actor than the principal, and never fall back to a system actor.

## `AshAgent.DigestKey`

```elixir
@callback digest_key(invocation) :: {:ok, binary} | {:error, term}
```

1. Return the HMAC key for the row's `args_digest`. It is called with the stored row, or with the row about to be
   inserted after every change of the request has run, so a column your own change sets on `request` is there.
2. If you encrypt content per subject, derive the key from that subject's key, so destroying the subject's key also
   makes the digest unrecomputable.
3. The same row must always give the same key: `invoke` compares a new request's digest with the stored one.
