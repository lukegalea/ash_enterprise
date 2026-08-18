defmodule AshEnterprise.Accounts.User do
  @moduledoc """
  A person who can sign in, and the actor every policy is evaluated against.

  Business-owned rather than user-owned, which has a consequence worth knowing
  before writing a policy over users -- see the comment below.
  """
  # Dataverse's `systemuser` is BusinessOwned: a user belongs to a business unit
  # rather than being owned by a principal. So Local/Deep depth checks work on
  # users, but Basic does not -- there is no owner to compare an actor against.
  #
  # Tenancy and soft delete are off for now:
  #   - tenant?: Organization does not exist yet (Phase 5). Turning it on before
  #     then would make organization_id required with nothing to point at, and
  #     would break registration.
  #   - archival?: sign-in looks users up by email. A soft-deleted user must not
  #     silently remain authenticable, and Dataverse models this as
  #     `isdisabled`/`state_code` rather than deletion. Deactivation, not archival.
  use AshEnterprise.Platform.Resource,
    otp_app: :ash_enterprise,
    domain: AshEnterprise.Accounts,
    ownership: :business_owned,
    tenant?: false,
    archival?: false,
    cdm_entity: "SystemUser",
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at
        auto_confirm_actions [:sign_in_with_magic_link, :reset_password_with_token]
        sender AshEnterprise.Accounts.User.Senders.SendNewUserConfirmationEmail
      end
    end

    tokens do
      enabled? true
      token_resource AshEnterprise.Accounts.Token
      signing_secret AshEnterprise.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender AshEnterprise.Accounts.User.Senders.SendPasswordResetEmail
          # these configurations will be the default in a future release
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      remember_me :remember_me
    end
  end

  postgres do
    table "users"
    repo AshEnterprise.Repo
  end

  actions do
    defaults [:read]

    update :assign_manager do
      description """
      Sets the user's manager. Security-relevant when hierarchy security runs in
      `:manager` mode: it changes what the manager can reach without touching any
      role.
      """

      accept [:manager_id]
      require_atomic? false
      validate AshEnterprise.Accounts.Validations.NoManagerCycle
    end

    update :assign_position do
      description """
      Places the user in the job hierarchy. Security-relevant when hierarchy
      security runs in `:position` mode.
      """

      accept [:position_id]
      require_atomic? false
    end

    update :assign_to_business_unit do
      description """
      Places a user in the organizational hierarchy.

      This is a security-relevant operation, not an administrative detail: a
      user's business unit is what `:local` and `:deep` grants are evaluated
      against, so moving someone between units silently changes what every role
      they hold can reach.

      Deliberately a named action rather than a generic `:update`. It shows up in
      the audit log as `assign_to_business_unit` rather than as an anonymous
      update, which is the difference between an auditable reorganization and a
      row that changed for unknown reasons.
      """

      accept [:owning_business_unit_id]
      require_atomic? false
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :change_password do
      # Use this action to allow users to change their password by providing
      # their current password and a new password.

      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    read :sign_in_with_token do
      # In the generated sign in components, we validate the
      # email and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.
      # This action performs that exchange. If you do not use the generated
      # liveviews, you may remove this action, and set
      # `sign_in_tokens_enabled? false` in the password strategy.

      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    create :register_with_password do
      description "Register a new user with a email and password."

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # Sets the email from the argument
      change set_attribute(:email, arg(:email))

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      # creates a reset token and invokes the relevant senders
      run {AshAuthentication.Strategy.Password.RequestPasswordReset, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    update :reset_password_with_token do
      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange
    end
  end

  # No `policies` block: the `ash_authentication` bypass is contributed by
  # `AshEnterprise.Security.Policies`, which detects the extension. Declaring it
  # here instead would place it *after* the inherited grant union -- policies run
  # in declaration order and the inherited set is injected by `use` -- so the
  # union would forbid the nil actor first and sign-in would collapse to
  # `filter false` before the password was ever checked.

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :confirmed_at, :utc_datetime_usec
  end

  relationships do
    belongs_to :manager, __MODULE__ do
      public? true
      attribute_writable? true
      source_attribute :manager_id

      description """
      The user this one reports to. Dataverse calls this `parentsystemuserid` and
      surfaces it as "Manager".

      Drives hierarchy security in `:manager` mode: a manager reaches records
      owned by their reports without holding any role that names those records.
      """
    end

    has_many :direct_reports, __MODULE__ do
      public? true
      destination_attribute :manager_id
    end

    belongs_to :position, AshEnterprise.Accounts.Position do
      public? true
      attribute_writable? true

      description """
      The user's node in the job hierarchy. Drives hierarchy security in
      `:position` mode, which -- unlike manager mode -- reaches across business
      units.
      """
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
