defmodule AshEnterprise.Accounts.UserIdentity do
  @moduledoc """
  The link between a user and their account at the deployment's OpenID Connect
  identity provider: the provider's stable subject (`uid`, the `sub` claim) under
  the strategy that asserted it (`strategy`, `"oidc"`). ADR 0071.

  The `ash_authentication` OIDC strategy reads and writes it while signing a person
  in (`User :sign_in_with_oidc`). One subject belongs to one user, permanently, and
  one user has at most one subject per strategy: the strategy refuses a sign-in
  that would break either rule. A row is created only by a sign-in that matched a
  confirmed, active user whose email the provider asserts as verified; nothing here
  creates a user.

  The provider's access and refresh tokens are **not kept**. The extension declares
  columns for them, but this application signs people in with the provider and calls
  nothing on their behalf, so `:upsert` discards both before the write
  (`Changes.DiscardProviderTokens`). The columns stay because the extension's
  verifier requires them; they are always empty. The `user_info` and `oauth_tokens`
  arguments are `sensitive?`, so the audit log keeps neither.

  Audited like any platform resource: linking a provider subject to an account is a
  change to how that account can be entered. Not tenant-scoped (a user is not a
  tenant row, and a sign-in happens before a tenant is resolved). Deleted with its
  user.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    authentication_plumbing?: true,
    extensions: [AshAuthentication.UserIdentity]

  user_identity do
    user_resource AshEnterprise.Accounts.User
  end

  postgres do
    table "user_identities"
    repo AshEnterprise.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      description """
      Links a provider subject to a user, or touches the existing link. Run only by the
      OIDC sign-in, after it matched the user. The provider's tokens are discarded.
      """

      upsert? true
      upsert_identity :unique_on_strategy_and_uid
      # The user a subject belongs to is set once, on insert, and never re-pointed.
      upsert_fields [:access_token, :access_token_expires_at, :refresh_token]
      accept [:strategy]

      argument :user_info, :map, allow_nil?: false, sensitive?: true
      argument :oauth_tokens, :map, allow_nil?: false, sensitive?: true
      argument :user_id, :uuid, allow_nil?: false

      change AshAuthentication.UserIdentity.UpsertIdentityChange
      change AshEnterprise.Accounts.Changes.DiscardProviderTokens
    end
  end

  identities do
    identity :unique_on_strategy_and_uid, [:strategy, :uid]
  end
end
