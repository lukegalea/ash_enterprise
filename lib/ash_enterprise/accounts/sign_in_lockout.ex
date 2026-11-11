defmodule AshEnterprise.Accounts.SignInLockout do
  @moduledoc """
  The failed-sign-in counter for one identity, kept in Postgres.

  One row per identity, keyed by a SHA-256 digest of the normalized email, so
  the table never holds an address and an address nobody registered counts the
  same as one somebody did. The row is advanced by a single atomic upsert
  (`:record_failure`), which is what makes the count hold across processes and
  nodes: there is no read-modify-write for two requests to interleave.

  Use `AshEnterprise.Accounts.Lockout`, not this resource, from other code.

  ## Why it is not audited

  Audit and lineage are off here, locally and on purpose. This is a counter
  written by pre-authentication requests, advanced by an atomic upsert with no
  changeset data for an event to record, and a failed attempt is not a change
  to a business record. Sign-in outcomes belong in the sign-in audit trail.
  """
  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    ownership: :none,
    tenant?: false,
    archival?: false,
    lifecycle?: false,
    audit?: false,
    lineage?: false,
    authentication_plumbing?: true

  postgres do
    table "sign_in_lockouts"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      sensitive? true
    end

    attribute :failed_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :window_started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :locked_until, :utc_datetime_usec do
      public? true
    end
  end

  identities do
    identity :unique_key, [:key]
  end

  actions do
    defaults [:read, :destroy]

    read :by_key do
      get? true
      argument :key, :string, allow_nil?: false
      filter expr(key == ^arg(:key))
    end

    create :record_failure do
      description """
      Counts one failed sign-in for `key`, in one atomic upsert. A failure while
      the identity is locked changes nothing; one outside the window, or after a
      lock has lapsed, starts the count again at 1.
      """

      accept [:key]
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:failed_count, :window_started_at, :locked_until]

      argument :now, :utc_datetime_usec, allow_nil?: false
      argument :window_cutoff, :utc_datetime_usec, allow_nil?: false
      argument :lock_until, :utc_datetime_usec, allow_nil?: false
      argument :max_attempts, :integer, allow_nil?: false

      change AshEnterprise.Accounts.Changes.AdvanceLockout
    end
  end
end
