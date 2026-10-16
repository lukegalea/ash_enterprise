defmodule AshEnterprise.Mdm do
  @moduledoc """
  Master data management (ADR 0054; plan `docs/plans/ash-mdm.md`): the host
  domain instantiating `ash_mdm`'s resource macros on the platform base and
  owning the orchestration glue — import batches, banding, stewardship,
  survivorship and egress.

  The golden records live in `AshEnterprise.Canonical`; this domain adds the
  per-customer ingress/egress machinery that never requires a deploy: mappings
  are versioned data, and activating one is a person-gated action, not a
  release.
  """

  use Ash.Domain, extensions: [AshPhoenix]

  resources do
    resource AshEnterprise.Mdm.Mapping
    resource AshEnterprise.Mdm.ImportBatch
    resource AshEnterprise.Mdm.StagedRecord
    resource AshEnterprise.Mdm.SourceRecord
    resource AshEnterprise.Mdm.MatchRuleSet
    resource AshEnterprise.Mdm.MatchCandidate
    resource AshEnterprise.Mdm.SourceIdentity
    resource AshEnterprise.Mdm.MappingProposal
  end
end
