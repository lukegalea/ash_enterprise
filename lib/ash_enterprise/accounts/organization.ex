defmodule AshEnterprise.Accounts.Organization do
  @moduledoc """
  A tenant. Every other row in the system belongs to exactly one of these.

  ## Why this is hand-written

  The Dataverse `organization` table has **505 columns** — verified by the
  scraper, see `priv/cdm/resolved/dataverse_organization.json`. It is a singleton
  settings table holding every org-wide preference: fiscal calendar, email
  behaviour, feature switches, audit toggles, formatting defaults.

  Generating that would produce 505 attributes of noise for the dozen that
  matter. So this is the one entity we deliberately transcribe by hand, taking
  the identity and defaults fields and leaving the settings surface for later —
  when a specific setting is actually needed, add that column and cite it.

  This is the "delete the 80% you do not need" step from
  `docs/manifesto/02-schema-commons.md` taken to its limit.

  ## Why it is not itself multi-tenant

  It *is* the tenant. `tenant?: false` here is not an opt-out of the platform's
  tenancy model — it is the base case of it. Every other resource carries an
  `organization_id` pointing at one of these rows.

  Likewise `ownership: :organization_owned`: in Dataverse this table is
  OrganizationOwned, so only Organization/None access levels are meaningful.
  Nobody "owns" the tenant.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    api_type: :organization,
    ownership: :organization_owned,
    tenant?: false,
    cdm_entity: "Organization"

  postgres do
    table "organizations"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints max_length: 160
      description "Display name of the tenant."
    end

    attribute :unique_name, :string do
      allow_nil? false
      public? true
      constraints max_length: 80, match: ~r/^[a-z0-9][a-z0-9\-]*$/

      description """
      Stable, URL-safe identifier. Used in subdomains and tenant routing, so it
      is immutable once set -- renaming would break every existing link.
      """
    end

    attribute :languagelocale_id, :uuid do
      public? true
      description "Default locale for users who have not chosen one."
    end

    attribute :base_currency_id, :uuid do
      public? true

      description """
      The tenant's reporting currency. Dataverse stores every monetary value
      twice -- once in the transaction currency and once converted to this one --
      so that cross-currency reporting does not have to join exchange rates.
      """
    end

    # First-party (no CDM column): ADR 0042 requires the disclosure control
    # for data leaving a zone to be an opt-in, recorded per tenant. Recorded
    # means data -- this column -- not config, and the update that flips it
    # lands in the audit event log like any other. Read by
    # `AshEnterprise.Zones.ResidencyPolicy`, next to the inference client.
    # Not public: it is a governance record, not part of the organization's
    # API surface.
    attribute :sub_processor_opt_in, :boolean do
      allow_nil? false
      default false
      public? false

      description """
      Whether this tenant has recorded an opt-in to customer-confidential
      data flowing to an instrument outside every declared zone (a
      sub-processor). Default false, and `AshEnterprise.Zones.ResidencyPolicy`
      treats absence, unknown tenants and read failures as false: no tenant
      opts in by silence. ADR 0042.
      """
    end
  end

  identities do
    # Deliberately `all_tenants?` is irrelevant here: this resource is not
    # tenant-scoped, so the uniqueness is genuinely global.
    identity :unique_name, [:unique_name]
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :name,
      :unique_name,
      :languagelocale_id,
      :base_currency_id,
      :sub_processor_opt_in
    ]

    create :create do
      primary? true
      description "Provision a tenant. See AshEnterprise.Accounts.Provisioning for the full flow."
    end

    update :update do
      primary? true
      # unique_name is immutable -- see the attribute description.
      accept [:name, :languagelocale_id, :base_currency_id, :sub_processor_opt_in]
    end
  end

  code_interface do
    define :create
    define :read
    define :by_unique_name, action: :read, get_by: [:unique_name]
  end
end
