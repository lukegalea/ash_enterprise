defmodule AshEnterprise.Contracts.Party do
  @moduledoc "Party compatibility resource over the existing CLM party relation."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    cdm_entity: "Party",
    extra_extensions: [AshStrangler.Resource],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table("parties")
    schema("strangler")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true)
    attribute(:legal_name, :string, allow_nil?: false, public?: true)
    attribute(:client_id, :string, public?: true)
    attribute(:metadata, :map, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
  end

  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "canonical_parties"
    publish_all :create, ["created"]
    publish_all :update, ["updated"]
    publish_all :destroy, ["destroyed"]
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.ClmParties do
      notify?(true)
      key(:id, from: :id, strategy: :identity)
      map(:legal_name, from: :name)
      map(:client_id, from: :client_id)
      map(:metadata, from: :metadata)
      map(:created_on, from: :created_at, zone: "UTC")

      unmapped(
        [
          :modified_on,
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id,
          :overridden_created_on,
          :import_sequence_number,
          :version_number
        ],
        as: :null,
        because: "The CLM party table has no modification or other platform provenance columns."
      )
    end
  end
end

defmodule AshEnterprise.Contracts.PartyFromVendor do
  @moduledoc "Party-shaped compatibility resource over vendorpm.vendors."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    cdm_entity: "Party",
    extra_extensions: [AshStrangler.Resource]

  postgres do
    table("vendor_parties")
    schema("strangler")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true)
    attribute(:legal_name, :string, allow_nil?: false, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:phone, :string, public?: true)
    attribute(:verified_status, :string, public?: true)
    attribute(:blacklisted, :boolean, public?: true)
    attribute(:onboarding, :boolean, public?: true)
  end

  actions do
    defaults([:read])
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.Vendors do
      notify?(true)
      key(:id, from: :id, strategy: {:uuid_v5, namespace: "ce41843a-c056-4c3e-9c79-50e7e5f4887c"})
      map(:legal_name, from: :company)
      map(:email, from: :email)
      map(:phone, from: :phone)
      map(:verified_status, from: :verified_status)
      map(:blacklisted, from: :blacklisted)
      map(:onboarding, from: :onboarding)
      map(:created_on, from: :created)

      unmapped(
        [
          :modified_on,
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id,
          :overridden_created_on,
          :import_sequence_number,
          :version_number
        ],
        as: :null,
        because: "VendorPM records no modification or other platform provenance on vendor rows."
      )
    end
  end
end

defmodule AshEnterprise.Contracts.PartyFromEnterprise do
  @moduledoc "Party-shaped compatibility resource over vendorpm.enterprises."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    cdm_entity: "Party",
    extra_extensions: [AshStrangler.Resource]

  postgres do
    table("enterprise_parties")
    schema("strangler")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true)
    attribute(:legal_name, :string, allow_nil?: false, public?: true)
    attribute(:data_region, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.Enterprises do
      notify?(true)
      key(:id, from: :id, strategy: {:uuid_v5, namespace: "ce41843a-c056-4c3e-9c79-50e7e5f4887c"})
      map(:legal_name, from: :company)
      map(:data_region, from: :data_region)
      map(:created_on, from: :created)

      unmapped(
        [
          :modified_on,
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id,
          :overridden_created_on,
          :import_sequence_number,
          :version_number
        ],
        as: :null,
        because:
          "Enterprise feature flags and archive state are configuration, not Party data; modification and actor provenance are absent."
      )
    end
  end
end

defmodule AshEnterprise.Contracts.ContractingProcess do
  @moduledoc "Contracting process compatibility resource over vendorpm.rfqs."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    cdm_entity: "ContractingProcess",
    extra_extensions: [AshStrangler.Resource]

  postgres do
    table("contracting_processes")
    schema("strangler")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true)
    attribute(:ocid, :string, allow_nil?: false, public?: true)
    attribute(:title, :string, public?: true)
    attribute(:deadline, :utc_datetime, public?: true)
    attribute(:cancel_reason, :string, public?: true)

    attribute(:lifecycle_status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:draft, :published, :cancelled]]
    )
  end

  actions do
    defaults([:read])
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.Rfqs do
      notify?(true)
      key(:id, from: :id, strategy: {:uuid_v5, namespace: "ce41843a-c056-4c3e-9c79-50e7e5f4887c"})

      map(:ocid,
        from: expr("ocds-vpm-" <> type(id, :string)),
        read_only?: true,
        because:
          "The legacy RFQ has only an integer id; OCID is a new canonical identity and cannot be written back safely."
      )

      map(:title, from: :additional_message)
      map(:deadline, from: :deadline)
      map(:cancel_reason, from: :cancel_reason)

      collapse :lifecycle_status do
        hit_policy(:first)

        state(:cancelled,
          when: expr(not is_nil(cancelled)),
          set: [submitted: nil, cancelled: touch()]
        )

        state(:published,
          when: expr(not is_nil(submitted)),
          set: [submitted: touch(), cancelled: nil]
        )

        state(:draft,
          when: :otherwise,
          set: [submitted: nil, cancelled: nil]
        )
      end

      map(:created_on, from: :created)
      map(:modified_on, from: :last_modified)

      unmapped(
        [
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id,
          :overridden_created_on,
          :import_sequence_number,
          :version_number
        ],
        as: :null,
        because: "The RFQ has no tenant, ownership, or platform provenance columns."
      )
    end
  end
end

defmodule AshEnterprise.Contracts.PartyRole do
  @moduledoc "Party-role compatibility resource over vendorpm.rfq_responses."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    cdm_entity: "PartyRole",
    extra_extensions: [AshStrangler.Resource]

  postgres do
    table("party_roles")
    schema("strangler")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true)
    attribute(:legacy_rfq_id, :integer, allow_nil?: false, public?: true)
    attribute(:legacy_party_id, :integer, allow_nil?: false, public?: true)
    attribute(:role, :string, allow_nil?: false, public?: true)
    attribute(:interested, :boolean, public?: true)
    attribute(:reason, :string, public?: true)
    attribute(:additional_insured_document, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.RfqResponses do
      notify?(true)
      key(:id, from: :id, strategy: {:uuid_v5, namespace: "ce41843a-c056-4c3e-9c79-50e7e5f4887c"})
      map(:legacy_rfq_id, from: :rfq_id)
      map(:legacy_party_id, from: :vendor_id)
      constant(:role, expr(type("supplier", :string)))
      map(:interested, from: :interested)
      map(:reason, from: :reason)
      map(:additional_insured_document, from: :additional_insured_document)
      map(:created_on, from: :created)

      unmapped(
        [
          :modified_on,
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id,
          :overridden_created_on,
          :import_sequence_number,
          :version_number
        ],
        as: :null,
        because: "The response relation has no canonical party UUID or platform provenance."
      )
    end
  end
end

defmodule AshEnterprise.Contracts.Contract do
  @moduledoc "Canonical Contract compatibility resource over public.clm_contracts."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    cdm_entity: "Contract",
    extra_extensions: [AshStrangler.Resource],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table("contracts")
    schema("strangler")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:description, :string, public?: true)
    attribute(:effective_date, :date, public?: true)
    attribute(:expiry_date, :date, public?: true)
    attribute(:value, :decimal, public?: true)
    attribute(:payment_term, :string, public?: true)
    attribute(:clauses, :map, allow_nil?: false, public?: true)
    attribute(:metadata, :map, allow_nil?: false, public?: true)
    attribute(:service_provider_party_id, :uuid, public?: true)
    attribute(:client_party_id, :uuid, public?: true)

    attribute(:lifecycle_status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:processing, :unverified, :active, :archived]]
    )
  end

  relationships do
    # Both party foreign keys are real uuid columns on the view, carried straight
    # from `clm_contracts."serviceProviderPartyId"` / `"clientPartyId"`, and the
    # Party id is the identity-mapped `clm_parties.id` -- so the join is the
    # legacy schema's own. The attributes already exist above, hence
    # `define_attribute? false`: the relationship reads them, it does not own
    # them.
    belongs_to :service_provider_party, AshEnterprise.Contracts.Party do
      public? true
      define_attribute? false

      description "The CLM party supplying the service."
    end

    belongs_to :client_party, AshEnterprise.Contracts.Party do
      public? true
      define_attribute? false

      description "The CLM party receiving the service."
    end
  end

  actions do
    defaults([:read])
  end

  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "canonical_contracts"
    publish_all :create, ["created"]
    publish_all :update, ["updated"]
    publish_all :destroy, ["destroyed"]
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.ClmContracts do
      notify?(true)
      key(:id, from: :id, strategy: :identity)
      map(:name, from: :name)
      map(:description, from: :description)
      map(:effective_date, from: :effective_date)
      map(:expiry_date, from: :expiry_date)
      map(:value, from: :value)
      map(:payment_term, from: :payment_term)
      map(:clauses, from: :clauses)
      map(:metadata, from: :metadata)
      map(:service_provider_party_id, from: :service_provider_party_id)
      map(:client_party_id, from: :client_party_id)

      collapse :lifecycle_status do
        hit_policy(:first)

        state(:archived,
          when: expr(not is_nil(archived)),
          set: [processed: false, verified: false, archived: touch()]
        )

        state(:unverified,
          when: expr(processed and not verified),
          set: [processed: true, verified: false, archived: nil]
        )

        state(:active,
          when: expr(processed and verified),
          set: [processed: true, verified: true, archived: nil]
        )

        state(:processing,
          when: :otherwise,
          set: [processed: false, verified: false, archived: nil]
        )
      end

      map(:created_on, from: :created_at, zone: "UTC")

      unmapped(
        [
          :modified_on,
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id,
          :overridden_created_on,
          :import_sequence_number,
          :version_number
        ],
        as: :null,
        because:
          "The CLM contract table has creation time but no platform modification or provenance columns."
      )
    end
  end
end

defmodule AshEnterprise.Contracts.ContractLine do
  @moduledoc "Contract-line compatibility resource over vendorpm.quotes."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    cdm_entity: "ContractLine",
    extra_extensions: [AshStrangler.Resource]

  postgres do
    table("contract_lines")
    schema("strangler")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true)
    attribute(:legacy_rfq_id, :integer, allow_nil?: false, public?: true)
    attribute(:legacy_party_id, :integer, allow_nil?: false, public?: true)
    attribute(:total_price, :decimal, allow_nil?: false, public?: true)
    attribute(:submitted, :utc_datetime, public?: true)
    attribute(:procurement_review_complete, :boolean, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.Quotes do
      notify?(true)
      key(:id, from: :id, strategy: {:uuid_v5, namespace: "ce41843a-c056-4c3e-9c79-50e7e5f4887c"})
      map(:legacy_rfq_id, from: :rfq_id)
      map(:legacy_party_id, from: :vendor_id)
      map(:total_price, from: :total_price)
      map(:submitted, from: :submitted)
      map(:procurement_review_complete, from: :procurement_review_complete)
      map(:created_on, from: :created)
      map(:modified_on, from: :updated)

      unmapped(
        [
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id,
          :overridden_created_on,
          :import_sequence_number,
          :version_number
        ],
        as: :null,
        because: "Quotes have no canonical contract foreign key or platform provenance."
      )
    end
  end
end

defmodule AshEnterprise.Contracts.Commitment do
  @moduledoc "Commitment compatibility resource over compliance document assurances."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    cdm_entity: "Commitment",
    extra_extensions: [AshStrangler.Resource],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table("commitments")
    schema("strangler")
    repo(AshEnterprise.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, public?: true)
    attribute(:legacy_party_id, :integer, allow_nil?: false, public?: true)
    attribute(:commitment_type, :string, allow_nil?: false, public?: true)
    attribute(:status, :string, allow_nil?: false, public?: true)
    attribute(:effective_date, :utc_datetime, public?: true)
    attribute(:attachment, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
  end

  pub_sub do
    module AshEnterpriseWeb.Endpoint
    prefix "canonical_commitments"
    publish_all :create, ["created"]
    publish_all :update, ["updated"]
    publish_all :destroy, ["destroyed"]
  end

  strangler do
    phase(:read_from_legacy)

    source AshEnterprise.Legacy.Twins.ComplianceDocuments do
      notify?(true)
      key(:id, from: :id, strategy: {:uuid_v5, namespace: "ce41843a-c056-4c3e-9c79-50e7e5f4887c"})
      map(:legacy_party_id, from: :vendor_id)
      constant(:commitment_type, expr(type("compliance", :string)))
      map(:status, from: :status)
      map(:effective_date, from: :expiry_date)
      map(:attachment, from: :attachment)
      map(:created_on, from: :created)

      unmapped(
        [
          :modified_on,
          :created_by_id,
          :modified_by_id,
          :created_on_behalf_by_id,
          :modified_on_behalf_by_id,
          :overridden_created_on,
          :import_sequence_number,
          :version_number
        ],
        as: :null,
        because:
          "Compliance documents have no modification or actor provenance; attachment remains a legacy path until Artifact exists."
      )
    end
  end
end

defmodule AshEnterprise.Contracts.Amendment do
  @moduledoc "Canonical amendment resource; no legacy amendment table exists yet."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    archival?: false,
    cdm_entity: "Amendment"

  postgres do
    table("amendments")
    schema("canonical")
    repo(AshEnterprise.Repo)

    references do
      # The contract lives in the strangler schema (a compatibility view, for
      # now), and Postgres cannot put a real constraint against a view. The
      # join is application-level until canonical.contracts exists.
      reference :contract, ignore?: true
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:contract_id, :uuid, allow_nil?: false, public?: true)
    attribute(:amendment_number, :integer, allow_nil?: false, public?: true)
    attribute(:rationale, :string, public?: true)
    attribute(:description, :string, public?: true)
    attribute(:amended_at, :utc_datetime_usec, public?: true)
  end

  relationships do
    # `contract_id` is a real uuid column on canonical.amendments referencing
    # the canonical Contract id; `define_attribute? false` because the attribute
    # is declared above.
    belongs_to :contract, AshEnterprise.Contracts.Contract do
      allow_nil? false
      public? true
      define_attribute? false
    end
  end

  actions do
    defaults([:read, :destroy])
  end
end

defmodule AshEnterprise.Contracts.Milestone do
  @moduledoc "Canonical milestone resource; no legacy milestone table exists yet."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    cdm_entity: "Milestone"

  postgres do
    table("milestones")
    schema("canonical")
    repo(AshEnterprise.Repo)

    references do
      # Same view-FK reasoning as Amendment: contract is still a strangler
      # compatibility view; commitment is `strangler.commitments`. Constraints
      # would fail against views, so both joins stay application-level.
      reference :contract, ignore?: true
      reference :commitment, ignore?: true
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:contract_id, :uuid, allow_nil?: false, public?: true)
    attribute(:commitment_id, :uuid, public?: true)
    attribute(:milestone_code, :string, allow_nil?: false, public?: true)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:due_date, :date, public?: true)
    attribute(:notice_lead_days, :integer, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
  end

  relationships do
    # Both foreign keys are real uuid columns on canonical.milestones; the
    # commitment link is optional by design -- not every milestone hangs off an
    # assurance. `define_attribute? false` because both attributes are declared
    # above.
    belongs_to :contract, AshEnterprise.Contracts.Contract do
      allow_nil? false
      public? true
      define_attribute? false
    end

    belongs_to :commitment, AshEnterprise.Contracts.Commitment do
      public? true
      define_attribute? false
    end
  end

  actions do
    defaults([:read, :destroy])
  end
end

defmodule AshEnterprise.Contracts.Transaction do
  @moduledoc "Canonical transaction resource; VPM-11 found no contract-payment incumbent."

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Contracts,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    cdm_entity: "Transaction"

  postgres do
    table("transactions")
    schema("canonical")
    repo(AshEnterprise.Repo)

    references do
      # Contract and contract line are strangler compatibility views for now;
      # Postgres cannot constrain against a view, so both joins stay at the
      # application level. The `source_reference` identity is the real guard.
      reference :contract, ignore?: true
      reference :line, ignore?: true
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:contract_id, :uuid, allow_nil?: false, public?: true)
    attribute(:line_id, :uuid, public?: true)
    attribute(:amount, :decimal, allow_nil?: false, public?: true)
    attribute(:currency, :string, allow_nil?: false, public?: true)
    attribute(:value_date, :date, public?: true)
    attribute(:source, :string, allow_nil?: false, public?: true)
    attribute(:external_reference, :string, allow_nil?: false, public?: true)
  end

  relationships do
    # `contract_id` and `line_id` are real uuid columns on canonical.transactions
    # (the line link optional -- payments can land on the contract as a whole);
    # `define_attribute? false` because both attributes are declared above.
    belongs_to :contract, AshEnterprise.Contracts.Contract do
      allow_nil? false
      public? true
      define_attribute? false
    end

    belongs_to :line, AshEnterprise.Contracts.ContractLine do
      public? true
      define_attribute? false
    end
  end

  identities do
    identity(:source_reference, [:source, :external_reference])
  end

  actions do
    defaults([:read, :destroy])
  end
end
