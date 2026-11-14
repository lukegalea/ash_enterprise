# ADR 0071 — One OpenID Connect identity provider per deployment, matched to verified accounts only

- **Status:** accepted (2026-11-14)
- **Date:** 2026-11-14
- **Related:** ADR 0066 (every way in shares one standard), 0024 (crypto-shredding), 0043 (automation principals)

## Context

People could prove who they were with a password only. An organisation that runs its own identity provider wants its
people to sign in there, so that the provider owns their password policy, their second factor and the moment they
leave. `ash_authentication` ships an OpenID Connect strategy, a `UserIdentity` extension that records which provider
subject belongs to which user, and a sign-in path for strategies with registration turned off. Two choices were left to
this application: which accounts a provider may open, and how a deployment turns the strategy on.

The risk in federated sign-in is account takeover through an email match. A provider that lets anyone claim an address,
or one that does not check addresses at all, could otherwise open the account that happens to have that address here.

## Decision

1. **One provider per deployment, over OIDC.** `User` declares an `oidc :oidc` strategy whose issuer, client id, client
   secret and callback come from the deployment's environment (`OIDC_BASE_URL`, `OIDC_CLIENT_ID`,
   `OIDC_CLIENT_SECRET`, `OIDC_REDIRECT_URI`), read at runtime through `AshEnterprise.Secrets`. Authorisation-code
   flow with PKCE and a nonce. SAML, a provider per organisation, and SCIM provisioning are not part of this
   repository.
2. **No provisioning.** The strategy has registration turned off, so no user is ever created by a sign-in. People are
   provisioned the way they are today.
3. **A first sign-in links only to a verified match.** `User :sign_in_with_oidc` takes as its one candidate the user
   whose email equals the email the provider asserted, and only if that user is active and has confirmed the address
   here. The strategy then admits the provider's subject (`sub`) only if it is already linked to that user, or links it
   now when the provider marks the email verified (`email_verified`) and the user has no other link. A subject linked to
   another user, a second subject for a linked user, an unverified email, an unconfirmed or deactivated user, and an
   address with no account are all refused, and refused with the same message.
4. **The link is a row, and the provider's tokens are not kept.** `Accounts.UserIdentity` holds the strategy, the
   subject and the user. It is audited like any platform resource, and deleted with its user. This application calls
   nothing on the person's behalf, so the access and refresh tokens the provider returns are discarded before the row
   is written.
5. **It is a door like the others (ADR 0066).** Every attempt is an `AuthenticationEvent` at the `:oidc` door, an
   admission with the user or a refusal with one of `:unknown_identity`, `:inactive`, `:unconfirmed`,
   `:unverified_email` or `:identity_mismatch`, and never with the email or the subject. An admission the audit chain
   cannot hold is refused. The session token it issues has the same 8-hour life as a password sign-in.
6. **The strategy is declared only when the build is configured for it.** `config/config.exs` sets `oidc_sign_in?` from
   `OIDC_BASE_URL` at compile time, and `User` declares the strategy only when it is set.
   `ash_authentication_phoenix` renders a button for every declared strategy, so a deployment without a provider would
   otherwise show one that cannot work. Turning it on or off needs a recompile, as the token lifetime does.
7. **The second factor is the provider's.** No in-app second factor is added. A deployment that requires one requires
   it at its provider. Requiring the provider to assert one (an `amr` claim) is a later, separate decision.

## Consequences

- A person whose address here differs from their address at the provider cannot sign in through it until one of the
  two is changed. That is the rule working, but it will look like a fault the first time.
- The provider's discovery document is fetched when someone signs in. A provider the deployment cannot reach refuses
  every sign-in through it.
- A deactivated user's link survives deactivation, and the door refuses them anyway. Reactivating restores the link.
- Changing the provider's subject for a person (a new account at the provider) is refused until an operator deletes the
  old `UserIdentity` row.
- A template user turns the strategy on by setting `OIDC_BASE_URL` when compiling, not only at runtime.

## Reversal

Remove the strategy and `:sign_in_with_oidc` from `User`, the `:oidc` entries from `AuthenticationEvent` and
`Secrets`, and drop `Accounts.UserIdentity` with a generated migration. Password sign-in is untouched by any of it.
