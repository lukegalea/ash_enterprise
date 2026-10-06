defmodule AshEnterprise.Canonical.Account do
  @moduledoc """
  An identity in an external system (dogfood §11): the operator's Google
  account, a Slack workspace membership, a Meltano-tapped database. One row per
  `(provider, external_id)` — the anchor that says *which* upstream identity a
  stream of raw objects belongs to.

  Nango (ADR 0011) owns the OAuth edge; this resource records the *outcome* of
  a connection, never a connection id, and nothing here is ever an action
  argument.

  Organization-owned rather than user-owned: an account identity is the
  workspace's fact about a provider ("this tenant's Google account"), not one
  of the operator's personal rows — the operator's own rows are Person,
  Message, CalendarEvent and Task.

  Projection-derived like the rest of the domain, so `archival?`/`lifecycle?`
  are opted out for the same reasons as `Person`: replay reconstructs, soft
  delete would ghost the upsert identity, and the lifecycle pair carries no
  meaning here. No projector exists yet — accounts arrive with the Gmail/Slack
  verticals (ADR 0042's zone admission gates those).

  Source-of pair: for an account, the external identity *is* the source
  identity — a projected account's `provider` is the SourceObject's
  `external_system` and its `external_id` is the raw row's id. There is no
  second pair of columns carrying the same values, and `by_external/2` is the
  provider lookup under that equivalence.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :organization_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "canonical_accounts"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
      constraints max_length: 64

      description "Which external system: google_calendar, gmail, slack, postgres. Same vocabulary as SourceObject.external_system."
    end

    attribute :external_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 512
      description "The provider's own id for the account, verbatim."
    end

    attribute :display_name, :string do
      public? true
      constraints max_length: 256
      description "How the provider names the account, when it says."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_provider_account, [:provider, :external_id]
  end

  actions do
    defaults [:read]

    read :by_external do
      description """
      Look up the account behind an external identity. For accounts the
      provider identity is the source identity (see the moduledoc), so this is
      the provider lookup under that equivalence.

      KNOWN GAP (E1 review, fix owned by a dedicated E1 follow-up):
      SourceObject identity is `[external_system, external_id]` *without* the
      stream, and this lookup inherits that shape — two streams sharing an
      external id would land on one row here. Projectors disambiguate by
      filtering `source_metadata["stream"]` when they select their raw rows;
      until the identity is fixed, lookups cannot.
      """

      get? true
      argument :system, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false

      filter expr(provider == ^arg(:system) and external_id == ^arg(:id))
    end

    create :upsert_from_source do
      description "The replay write path: upsert on the provider identity."
      accept [:provider, :external_id, :display_name]

      upsert? true
      upsert_identity :unique_provider_account
      upsert_fields [:display_name]
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
  end
end
