defmodule AshEnterpriseWeb.A2ui.LegacyPartyUI do
  @moduledoc "A2UI surface over a legacy compatibility view."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.Party)
    surface_id("legacy_parties")
    title("Legacy parties")
    record_label("legacy party")

    query :default do
      search_fields([:legal_name, :client_id])
      sortable([:legal_name, :created_on])
      default_sort(legal_name: :asc)
      page_size(25)
    end

    component :table do
      fields([:legal_name, :client_id, :created_on])
      read_action(:read)
      query(:default)

      row_layout do
        title(:legal_name)
        meta([:client_id, :created_on])
        columns(2)
      end
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.LegacyVendorPartyUI do
  @moduledoc "A2UI surface over a legacy compatibility view."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.PartyFromVendor)
    surface_id("legacy_vendor_parties")
    title("Legacy vendor parties")
    record_label("legacy vendor party")

    query :default do
      search_fields([:legal_name, :email])
      sortable([:legal_name, :email])
      default_sort(legal_name: :asc)
      page_size(25)
    end

    component :table do
      fields([:legal_name, :email, :phone, :verified_status, :blacklisted, :onboarding])
      read_action(:read)
      query(:default)

      row_layout do
        title(:legal_name)
        badge(:verified_status)
        meta([:email, :phone, :blacklisted, :onboarding])
        columns(2)
      end
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.LegacyEnterprisePartyUI do
  @moduledoc "A2UI surface over a legacy compatibility view."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.PartyFromEnterprise)
    surface_id("legacy_enterprise_parties")
    title("Legacy enterprise parties")
    record_label("legacy enterprise party")

    query :default do
      search_fields([:legal_name, :data_region])
      sortable([:legal_name, :data_region, :created_on])
      default_sort(legal_name: :asc)
      page_size(25)
    end

    component :table do
      fields([:legal_name, :data_region, :created_on])
      read_action(:read)
      query(:default)

      row_layout do
        title(:legal_name)
        badge(:data_region)
        meta([:created_on])
        columns(1)
      end
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.LegacyContractingProcessUI do
  @moduledoc "A2UI surface over a legacy compatibility view."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.ContractingProcess)
    surface_id("legacy_contracting_processes")
    title("Legacy RFQs")
    record_label("legacy RFQ")

    query :default do
      search_fields([:ocid, :title, :cancel_reason])
      sortable([:ocid, :deadline, :lifecycle_status])
      default_sort(deadline: :desc)
      page_size(25)
    end

    component :table do
      fields([:ocid, :title, :deadline, :cancel_reason, :lifecycle_status])
      read_action(:read)
      query(:default)

      row_layout do
        title(:title)
        badge(:lifecycle_status)
        meta([:ocid, :deadline, :cancel_reason])
        columns(2)
      end
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.LegacyPartyRoleUI do
  @moduledoc "A2UI surface over a legacy compatibility view."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.PartyRole)
    surface_id("legacy_party_roles")
    title("Legacy party roles")
    record_label("legacy party role")

    query :default do
      search_fields([:role, :reason])
      sortable([:legacy_rfq_id, :legacy_party_id, :role])
      default_sort(legacy_rfq_id: :desc)
      page_size(25)
    end

    component :table do
      fields([:legacy_rfq_id, :legacy_party_id, :role, :interested, :reason])
      read_action(:read)
      query(:default)

      row_layout do
        title(:role)
        badge(:interested)
        meta([:legacy_rfq_id, :legacy_party_id, :reason])
        columns(2)
      end
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.LegacyContractUI do
  @moduledoc "A2UI surface over a legacy compatibility view."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.Contract)
    surface_id("legacy_contracts")
    title("Legacy contracts")
    record_label("legacy contract")

    query :default do
      search_fields([:name, :description, :payment_term])
      sortable([:name, :effective_date, :expiry_date, :value])
      default_sort(effective_date: :desc)
      page_size(25)
    end

    component :table do
      fields([
        :name,
        :description,
        :effective_date,
        :expiry_date,
        :value,
        :payment_term,
        :lifecycle_status
      ])

      read_action(:read)
      query(:default)

      row_layout do
        title(:name)
        badge(:lifecycle_status)
        meta([:effective_date, :expiry_date, :value, :payment_term])
        columns(2)
      end
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.LegacyContractLineUI do
  @moduledoc "A2UI surface over a legacy compatibility view."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.ContractLine)
    surface_id("legacy_contract_lines")
    title("Legacy contract lines")
    record_label("legacy contract line")

    query :default do
      sortable([:legacy_rfq_id, :legacy_party_id, :total_price, :submitted])
      default_sort(submitted: :desc)
      page_size(25)
    end

    component :table do
      fields([
        :legacy_rfq_id,
        :legacy_party_id,
        :total_price,
        :submitted,
        :procurement_review_complete
      ])

      read_action(:read)
      query(:default)

      row_layout do
        title(:legacy_rfq_id)
        badge(:procurement_review_complete)
        meta([:legacy_party_id, :total_price, :submitted])
        columns(2)
      end
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.LegacyCommitmentUI do
  @moduledoc "A2UI surface over a legacy compatibility view."
  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Contracts.Commitment)
    surface_id("legacy_commitments")
    title("Legacy commitments")
    record_label("legacy commitment")

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
