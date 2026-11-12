defmodule AshEnterprise.Accounts.Offboarding do
  @moduledoc """
  One leaver's offboarding in one organization: what the offboarding recipe did when a
  person was deactivated, and what they still hold there for a person to review.

  A deactivation is recorded in every organization the person belongs to
  (`AshEnterprise.Automation.Occurrences`, an `Automation.Occurrence` of type
  `user.deactivated`). The `offboarding` pack (`priv/packs/offboarding/`) installs a draft
  recipe that matches it and a draft process that runs the two targets declared here, then
  opens a review. Nothing runs until a person publishes the process and then the recipe with
  `publish_granted` (ADR 0069), so its steps run as the `recipe_runner` acting for that
  person, on the intersection of the two.

  ## The targets

  Both are generic actions a process names through `AshEnterprise.Process.ActionInvoker`
  (`offboarding_open`, `offboarding_revoke_credentials`) and runs through its invocation.
  Each takes the process subject, the occurrence, as `id`. Each writes this resource with the
  caller's own actor, so a generic action's `:read` grant is not what lets it write: the
  `create` or `write` grant on this resource is.

    * `open` reads the occurrence as the caller (so another organization's is not found, and
      a fact that is not a deactivation is refused), and records the leaver, whether they are
      still inactive, and what they hold here (`AshEnterprise.Accounts.Offboarding.Holdings`).
    * `revoke_credentials` looks at the leaver again and, while they are still inactive,
      revokes every stored token still live for them and archives every API key they still
      have. A person reactivated before the step runs is not touched: the row records
      `reactivated` and nothing is revoked.

  ## Why the revocation itself is not authorized as the runner

  Tokens and API keys belong to the account, not to an organization (`tenant?: false`), and
  only the sign-in machinery writes them. A grant on them would be a grant over every
  account's credentials. The revocation instead runs inside the `revoke_credentials` update,
  without a second authorization, the way the deactivation's own revocation does
  (`AshEnterprise.Accounts.Changes.RevokeTokensOnDeactivation`). It is bounded by
  construction: the update is authorized as the caller on this organization's row, and it
  acts only on the person a platform-written deactivation names, only while they are still
  inactive.

  ## What is not ended

  Role assignments, team memberships, start grants and break-glass sessions stay. Ending one
  is a `changes_authority` act that no automation principal may take, so a recipe never
  does it. While the account is inactive they are inert: sign-in, a bearer key, a person
  actor rebuilt for a step (`AshEnterprise.Execution.Identity`) and a standing grant all
  refuse an inactive person. The row lists them, with that reason, for the person who
  reviews the offboarding to end what should not come back on a reactivation.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    ownership: :organization_owned,
    lifecycle?: false,
    extra_extensions: [AshAgent.Effects]

  postgres do
    table "accounts_offboardings"
    repo AshEnterprise.Repo
  end

  effects do
    action :open,
      kind: :edit,
      read_only?: false,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :execute

    action :revoke_credentials,
      kind: :edit,
      read_only?: false,
      destructive?: true,
      idempotent?: true,
      open_world?: false,
      intent: :execute
  end

  attributes do
    uuid_primary_key :id

    attribute :occurrence_id, :uuid do
      allow_nil? false
      public? true
      description "The `user.deactivated` occurrence this offboarding answers."
    end

    attribute :leaver_id, :uuid do
      allow_nil? false
      public? true
      description "The person deactivated."
    end

    attribute :leaver_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:inactive, :reactivated]

      description "`inactive` while the person is still deactivated; `reactivated` when they were active again by the time a step looked, and nothing was revoked."
    end

    attribute :holdings, :map do
      allow_nil? false
      public? true
      default %{}

      description "What the leaver holds in this organization, for the review: counts by kind, and the assignments that stay and why they are inert."
    end

    attribute :sessions_revoked, :integer do
      allow_nil? false
      public? true
      default 0
      description "Stored tokens still live for the leaver that the offboarding revoked."
    end

    attribute :api_keys_revoked, :integer do
      allow_nil? false
      public? true
      default 0
      description "API keys the offboarding archived."
    end

    attribute :revoked_at, :utc_datetime_usec do
      public? true
      description "When the credentials were revoked; nil when nothing was."
    end
  end

  identities do
    identity :one_per_occurrence, [:occurrence_id]
  end

  actions do
    defaults [:read]

    create :record do
      description "Records a leaver's offboarding. Written by `open`."
      accept [:occurrence_id, :leaver_id, :leaver_state, :holdings]
    end

    update :revoke do
      description """
      Revokes the leaver's live stored tokens and archives their API keys, while they are
      still inactive; records `reactivated` and revokes nothing otherwise. Written by
      `revoke_credentials`.
      """

      accept []
      require_atomic? false
      change AshEnterprise.Accounts.Offboarding.Changes.RevokeLeaverCredentials
    end

    action :open, :map do
      description """
      Opens the offboarding of the person a `user.deactivated` occurrence names: records
      them, whether they are still inactive, and what they hold in this organization.
      Refuses an occurrence that is not a deactivation with `not_a_deactivation`.
      """

      argument :id, :uuid do
        allow_nil? false
        description "The occurrence."
      end

      run AshEnterprise.Accounts.Offboarding.Actions.Open
    end

    action :revoke_credentials, :map do
      description """
      Revokes the leaver's live sessions and API keys while they are still inactive, and
      answers `leaver` (`inactive` or `reactivated`) for the process to route on.
      """

      argument :id, :uuid do
        allow_nil? false
        description "The occurrence."
      end

      run AshEnterprise.Accounts.Offboarding.Actions.RevokeCredentials
    end
  end
end
