defmodule AshEnterpriseWeb.A2ui.CanonicalPartyUI do
  @moduledoc "A2UI surface over the canonical Party resource."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.Party)
    surface_id("canonical_parties")
    title("Canonical parties")
    record_label("canonical party")

    query :default do
      search_fields([:legal_name, :client_id])
      sortable([:legal_name, :created_on])
      default_sort(legal_name: :asc)
      page_size(25)
    end

    context :party do
      resource(AshEnterprise.Contracts.Party)
      picker(false)
    end

    component :table do
      fields([:legal_name, :client_id, :created_on])
      read_action(:read)
      query(:default)
      select_context(:party)

      row_layout do
        title(:legal_name)
        meta([:client_id, :created_on])
        columns(2)
      end
    end

    component :detail, :party_detail do
      context(:party)
      fields([:legal_name, :client_id, :created_on])
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.CanonicalContractUI do
  @moduledoc "A2UI surface over the canonical Contract resource."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.Contract)
    surface_id("canonical_contracts")
    title("Canonical contracts")
    record_label("canonical contract")

    context :contract do
      resource(AshEnterprise.Contracts.Contract)
      picker(false)
    end

    query :default do
      search_fields([:name, :description, :payment_term])
      sortable([:name, :effective_date, :expiry_date, :value])
      default_sort(effective_date: :desc)
      page_size(25)
    end

    component :table do
      fields([
        :name,
        :provider,
        :client,
        :description,
        :effective_date,
        :expiry_date,
        :value,
        :payment_term,
        :lifecycle_status
      ])

      read_action(:read)
      query(:default)
      select_context(:contract)

      row_layout do
        title(:name)
        badge(:lifecycle_status)
        meta([:effective_date, :expiry_date, :value, :payment_term])
        columns(2)
      end
    end

    component :detail, :contract_detail do
      context(:contract)
      fields([:name, :provider, :client, :effective_date, :expiry_date, :value, :payment_term])
    end

    field :provider do
      label("Provider")
      source([:service_provider_party, :legal_name])
      link(:service_provider_party)
    end

    field :client do
      label("Client")
      source([:client_party, :legal_name])
      link(:client_party)
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.CanonicalCommitmentUI do
  @moduledoc "A2UI surface over the canonical Commitment resource."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.Commitment)
    surface_id("canonical_commitments")
    title("Canonical commitments")
    record_label("canonical commitment")

    query :default do
      search_fields([:commitment_type, :status, :attachment])
      sortable([:legacy_party_id, :commitment_type, :status, :effective_date])
      default_sort(effective_date: :desc)
      page_size(25)
    end

    component :table do
      fields([:legacy_party_id, :commitment_type, :status, :effective_date, :attachment])
      read_action(:read)
      query(:default)

      row_layout do
        title(:commitment_type)
        badge(:status)
        meta([:legacy_party_id, :effective_date, :attachment])
        columns(2)
      end
    end
  end
end
