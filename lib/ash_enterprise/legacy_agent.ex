defmodule AshEnterprise.LegacyAgent do
  @moduledoc """
  AshAi tool catalogue for actors working in the legacy vocabulary.

  The route selects these read-only tools explicitly. AshAi still executes each
  action with the bearer actor, so the helper cannot see beyond that actors
  compatibility-view permissions.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAi]

  tools do
    tool :legacy_users, AshEnterprise.Legacy.User, :read
    tool :legacy_parties, AshEnterprise.Contracts.Party, :read
    tool :legacy_vendor_parties, AshEnterprise.Contracts.PartyFromVendor, :read
    tool :legacy_enterprise_parties, AshEnterprise.Contracts.PartyFromEnterprise, :read
    tool :legacy_contracting_processes, AshEnterprise.Contracts.ContractingProcess, :read
    tool :legacy_party_roles, AshEnterprise.Contracts.PartyRole, :read
    tool :legacy_contracts, AshEnterprise.Contracts.Contract, :read
    tool :legacy_contract_lines, AshEnterprise.Contracts.ContractLine, :read
    tool :legacy_commitments, AshEnterprise.Contracts.Commitment, :read
  end
end
