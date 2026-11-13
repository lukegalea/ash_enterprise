defmodule AshEnterprise.Security.AuthenticationEvent do
  @moduledoc """
  One admission or refusal at a sign-in door, as a row the audit chain records
  (SOC 2 CC7.2). Written only by `AshEnterprise.Security.AuthenticationAudit`.

  ## The doors

  | `door` | Admissions | Refusals |
  |---|---|---|
  | `:password` | every password sign-in (`User :sign_in_with_password`) | every one, known address or not: `:wrong_password`, `:unknown_identity`, `:inactive`, `:locked` |
  | `:password_reset` | every reset that signs the user in (`:reset_password_with_token`) | none |
  | `:confirmation` | every confirmation that signs the user in (`:confirm`) | none |
  | `:api_key` | none: a request it admits is not an event, or the chain would hold one row per API call | every key it refuses (unknown, expired, revoked, malformed, or a deactivated owner's): `:api_key_rejected` |

  A reset or confirmation link that does not verify, and a session bearer token that does
  not, identify nobody and reach the log only. Registration is refused in a deployment
  (`AshEnterprise.Accounts.Changes.RefuseSelfRegistration`) and is not a door here.

  ## What it carries

  The door, the outcome, a reason from a closed set, and the `user_id` the attempt
  resolved to when it resolved to one. Never an email, a password, a token or an API
  key: an attempt on an address that is no account is `:unknown_identity` with no
  `user_id`, so the table is not a list of every string typed into the sign-in box.

  ## Which chain

  Not tenant-scoped: a sign-in happens before any tenant is resolved, and a user is not
  a tenant row. The events are therefore in the audit log's untenanted chain
  (`AshEnterprise.Audit.EventLog`): they are written with no tenant, so nothing stamps
  an `organization_id` into their metadata.

  Append-only: the one write is `:record`, and only a system actor may make it.
  Reading is for the platform operator.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    # Declared in full below: the inherited grant union would let anyone holding a
    # create grant here write a sign-in that never happened.
    policies?: false

  @doors [:password, :password_reset, :confirmation, :api_key]

  @reasons [:wrong_password, :unknown_identity, :inactive, :locked, :api_key_rejected]

  @doc "The doors that record events."
  @spec doors() :: [atom()]
  def doors, do: @doors

  @doc "Every refusal reason an event can carry."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  postgres do
    table "authentication_events"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :door, :atom do
      allow_nil? false
      public? true
      constraints one_of: @doors
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:signed_in, :refused]
    end

    attribute :reason, :atom do
      public? true
      constraints one_of: @reasons
      description "Why the door refused. Nil for an admission."
    end

    attribute :user_id, :uuid do
      public? true
      description "The user the attempt resolved to. Nil when it resolved to nobody."
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end
  end

  validations do
    validate present(:reason), where: attribute_equals(:outcome, :refused)
    validate absent(:reason), where: attribute_equals(:outcome, :signed_in)
    validate present(:user_id), where: attribute_equals(:outcome, :signed_in)
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:door, :outcome, :reason, :user_id]
    end
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.PlatformOperator
    end
  end
end
