defmodule AshEnterprise.CanonicalAgent do
  @moduledoc "AshAi tool catalogue restricted to the canonical contracting vocabulary."

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAi]

  tools do
    tool :canonical_parties, AshEnterprise.Contracts.Party, :read
    tool :canonical_contracts, AshEnterprise.Contracts.Contract, :read
    tool :canonical_commitments, AshEnterprise.Contracts.Commitment, :read
  end
end
