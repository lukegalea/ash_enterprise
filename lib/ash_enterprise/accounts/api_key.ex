defmodule AshEnterprise.Accounts.ApiKey do
  @moduledoc """
  A bearer key for a user: API, MCP and ACP callers that are not a browser session.

  Three things hold for every key:

    * It expires. `expires_at` is required, in the future when issued, and no
      further out than `max_lifetime_days/0`.
    * It is only as alive as its owner. `User.valid_api_keys` (the relationship
      the sign-in reads) counts a key only while its owner is `:active`, and the
      sign-in action itself filters inactive owners too.
    * Only the SHA-256 of the key is stored. The plaintext is returned once, in
      the `plaintext_api_key` metadata of the issued record.

  Revoking is `destroy` (soft delete): an archived key is never read again.

  Issuing one is also recorded as an `accounts.api_key_issued` occurrence in each of the
  owner's organizations (`AshEnterprise.Accounts.Changes.RecordApiKeyIssue`), since a key's
  own audit row is in no tenant's chain; the `security_alerts` pack opens a review on it.

  A host sets the longest lifetime a key may be issued for:

      config :ash_enterprise, :api_key_max_lifetime_days, 90
  """
  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    authentication_plumbing?: true

  @default_max_lifetime_days 90

  @doc "The longest lifetime, in days, a key may be issued for."
  @spec max_lifetime_days() :: pos_integer()
  def max_lifetime_days do
    case Application.get_env(
           :ash_enterprise,
           :api_key_max_lifetime_days,
           @default_max_lifetime_days
         ) do
      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              "config :ash_enterprise, :api_key_max_lifetime_days must be a positive integer, " <>
                "got: #{inspect(other)}"
    end
  end

  postgres do
    table "api_keys"
    repo AshEnterprise.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :api_key_hash, :binary do
      allow_nil? false
      sensitive? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :user, AshEnterprise.Accounts.User do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  identities do
    identity :unique_hash, [:api_key_hash]
  end

  actions do
    defaults [:read, :destroy]

    create :issue do
      description "Issues a key for a user. The plaintext key is in the result's `plaintext_api_key` metadata, once."
      accept [:user_id, :name, :expires_at]

      validate AshEnterprise.Accounts.Validations.ApiKeyExpiry
      validate AshEnterprise.Accounts.Validations.ActiveOwner

      change {AshAuthentication.Strategy.ApiKey.GenerateApiKey, prefix: :aek, hash: :api_key_hash}
      change AshEnterprise.Accounts.Changes.RecordApiKeyIssue
    end
  end
end
