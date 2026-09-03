defmodule AshEnterprise.Legacy.Twins.ClmParties do
  @moduledoc "Twin for public.clm_parties, generated from the VPM-11 schema dump."

  use Ash.Resource,
    domain: AshEnterprise.Legacy.Twins,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table("clm_parties")
    schema("public")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:id, :uuid, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:client_id, :string, source: :"clientId", public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:metadata, :map, allow_nil?: false, public?: true)
    attribute(:created_at, :naive_datetime, allow_nil?: false, source: :"createdAt", public?: true)
  end
end

defmodule AshEnterprise.Legacy.Twins.ClmContracts do
  @moduledoc "Twin for public.clm_contracts, generated from the VPM-11 schema dump."

  use Ash.Resource,
    domain: AshEnterprise.Legacy.Twins,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table("clm_contracts")
    schema("public")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:id, :uuid, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:description, :string, public?: true)
    attribute(:effective_date, :date, source: :"effectiveDate", public?: true)
    attribute(:expiry_date, :date, source: :"expiryDate", public?: true)
    attribute(:value, :decimal, public?: true)
    attribute(:payment_term, :string, source: :"paymentTerm", public?: true)
    attribute(:clauses, :map, allow_nil?: false, public?: true)
    attribute(:metadata, :map, allow_nil?: false, public?: true)
    attribute(:processed, :boolean, public?: true)
    attribute(:verified, :boolean, public?: true)
    attribute(:archived, :naive_datetime, public?: true)
    attribute(:created_at, :naive_datetime, allow_nil?: false, source: :"createdAt", public?: true)
    attribute(:service_provider_party_id, :uuid, source: :"serviceProviderPartyId", public?: true)
    attribute(:client_party_id, :uuid, source: :"clientPartyId", public?: true)
  end
end

defmodule AshEnterprise.Legacy.Twins.Vendors do
  @moduledoc "Twin for vendorpm.vendors, generated from the VPM-11 schema dump."

  use Ash.Resource,
    domain: AshEnterprise.Legacy.Twins,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table("vendors")
    schema("vendorpm")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:id, :integer, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:company, :string, allow_nil?: false, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:phone, :string, public?: true)
    attribute(:verified_status, :string, public?: true)
    attribute(:blacklisted, :boolean, allow_nil?: false, public?: true)
    attribute(:onboarding, :boolean, allow_nil?: false, public?: true)
    attribute(:created, :utc_datetime, allow_nil?: false, public?: true)
  end
end

defmodule AshEnterprise.Legacy.Twins.Enterprises do
  @moduledoc "Twin for vendorpm.enterprises, generated from the VPM-11 schema dump."

  use Ash.Resource,
    domain: AshEnterprise.Legacy.Twins,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table("enterprises")
    schema("vendorpm")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:id, :integer, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:company, :string, allow_nil?: false, public?: true)
    attribute(:created, :utc_datetime, public?: true)
    attribute(:archived, :boolean, allow_nil?: false, public?: true)
    attribute(:clm_enabled, :boolean, allow_nil?: false, public?: true)
    attribute(:data_region, :string, allow_nil?: false, public?: true)
  end
end

defmodule AshEnterprise.Legacy.Twins.Rfqs do
  @moduledoc "Twin for vendorpm.rfqs, generated from the VPM-11 schema dump."

  use Ash.Resource,
    domain: AshEnterprise.Legacy.Twins,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table("rfqs")
    schema("vendorpm")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:id, :integer, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:deadline, :utc_datetime, public?: true)
    attribute(:created, :utc_datetime, public?: true)
    attribute(:cancelled, :utc_datetime, public?: true)
    attribute(:submitted, :utc_datetime, public?: true)
    attribute(:last_modified, :utc_datetime, public?: true)
    attribute(:cancel_reason, :string, public?: true)
    attribute(:additional_message, :string, public?: true)
    attribute(:public, :boolean, allow_nil?: false, public?: true)
  end
end

defmodule AshEnterprise.Legacy.Twins.RfqResponses do
  @moduledoc "Twin for vendorpm.rfq_responses, generated from the VPM-11 schema dump."

  use Ash.Resource,
    domain: AshEnterprise.Legacy.Twins,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table("rfq_responses")
    schema("vendorpm")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:id, :integer, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:rfq_id, :integer, allow_nil?: false, public?: true)
    attribute(:vendor_id, :integer, allow_nil?: false, public?: true)
    attribute(:interested, :boolean, public?: true)
    attribute(:reason, :string, public?: true)
    attribute(:created, :utc_datetime, public?: true)
    attribute(:archived, :utc_datetime, public?: true)
    attribute(:additional_insured_document, :string, public?: true)
  end
end

defmodule AshEnterprise.Legacy.Twins.Quotes do
  @moduledoc "Twin for vendorpm.quotes, generated from the VPM-11 schema dump."

  use Ash.Resource,
    domain: AshEnterprise.Legacy.Twins,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table("quotes")
    schema("vendorpm")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:id, :integer, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:rfq_id, :integer, allow_nil?: false, public?: true)
    attribute(:vendor_id, :integer, allow_nil?: false, public?: true)
    attribute(:created, :utc_datetime, public?: true)
    attribute(:submitted, :utc_datetime, public?: true)
    attribute(:updated, :utc_datetime, public?: true)
    attribute(:total_price, :decimal, allow_nil?: false, public?: true)
    attribute(:procurement_review_complete, :boolean, allow_nil?: false, public?: true)
  end
end

defmodule AshEnterprise.Legacy.Twins.ComplianceDocuments do
  @moduledoc "Twin for vendorpm.compliance_documents, generated from the VPM-11 schema dump."

  use Ash.Resource,
    domain: AshEnterprise.Legacy.Twins,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table("compliance_documents")
    schema("vendorpm")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:id, :integer, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:vendor_id, :integer, allow_nil?: false, public?: true)
    attribute(:type, :string, allow_nil?: false, public?: true)
    attribute(:status, :string, allow_nil?: false, public?: true)
    attribute(:expiry_date, :utc_datetime, public?: true)
    attribute(:attachment, :string, allow_nil?: false, public?: true)
    attribute(:created, :utc_datetime, public?: true)
  end
end