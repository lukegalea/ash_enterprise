defmodule AshEnterprise.Mdm.MatchCandidate do
  @moduledoc """
  One (staged record, golden record) candidate pair with its score and
  per-rule explanation. Candidate generation runs as a system actor
  (ADR 0017's first sharp edge); the REVIEW SURFACE is filtered separately
  — a steward never learns of a candidate they cannot read.

  Nothing custom: the platform base's grant union (RoleGrant,
  SharedWithActor, HierarchyGrant) governs, with the engine bypasses.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false

  use AshMdm.Resources, {:match_candidate, []}

  postgres do
    table "mdm_match_candidates"
    repo AshEnterprise.Repo
  end
end
