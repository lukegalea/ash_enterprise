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
  end

  identities do
    # Deliberately `all_tenants?` is irrelevant here: this resource is not
    # tenant-scoped, so the uniqueness is genuinely global.
    identity :unique_name, [:unique_name]
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:name, :unique_name, :languagelocale_id, :base_currency_id]

    create :create do
      primary? true
      description "Provision a tenant. See AshEnterprise.Accounts.Provisioning for the full flow."
    end

    update :update do
      primary? true
      # unique_name is immutable -- see the attribute description.
      accept [:name, :languagelocale_id, :base_currency_id]
    end
  end

  code_interface do
    define :create
    define :read
    define :by_unique_name, action: :read, get_by: [:unique_name]
  end
end
