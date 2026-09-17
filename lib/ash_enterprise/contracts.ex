defmodule AshEnterprise.Contracts do
  @moduledoc "Canonical contracting resources and their legacy compatibility surfaces."

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  resources do
    resource AshEnterprise.Contracts.Party
    resource AshEnterprise.Contracts.PartyFromVendor
    resource AshEnterprise.Contracts.PartyFromEnterprise
    resource AshEnterprise.Contracts.ContractingProcess
    resource AshEnterprise.Contracts.PartyRole
    resource AshEnterprise.Contracts.Contract
    resource AshEnterprise.Contracts.ContractLine
    resource AshEnterprise.Contracts.Commitment
    resource AshEnterprise.Contracts.Amendment
    resource AshEnterprise.Contracts.Milestone
    resource AshEnterprise.Contracts.Transaction
  end
end
