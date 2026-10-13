defmodule AshEnterprise.Mdm.MatchRuleSet do
  @moduledoc """
  Per-tenant match rules as data (ADR 0017/0050): one row per golden
  resource VERSION — `%{kind: :exact, fields: [...], weight: w}` and
  `%{kind: :fuzzy, field: :name, algorithm: :trigram|:levenshtein, weight: w}`.
  No thresholds — those are band tables (ADR 0041). Activation supersedes
  and is person-gated, exactly like Mapping.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    policies?: false

  use AshMdm.Resources, {:match_rule_set, repo: AshEnterprise.Repo, table: "mdm_match_rule_sets"}

  code_interface do
    define :by_id, action: :read, get_by: [:id], not_found_error?: false
  end

  policies do
    # Same shape as Mapping: the person-only gate is activation (a match
    # policy is a decision about what merges without a human); reads and
    # drafts follow the grant union.
    policy action(:activate) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    bypass AshBpmn.Checks.AshBpmnInteraction do
      authorize_if always()
    end

    bypass AshDecisions.Checks.AshDecisionsInteraction do
      authorize_if always()
    end

    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy always() do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
      authorize_if AshEnterprise.Security.Checks.SharedWithActor
    end
  end
end

defmodule AshEnterprise.Mdm.MatchCandidate do
  @moduledoc """
  One (staged record, golden record) candidate pair with its score and
  per-rule explanation. Candidate generation runs as a system actor
  (ADR 0017's first sharp edge); the REVIEW SURFACE is filtered separately
  — a steward never learns of a candidate they cannot read.
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

  policies do
    bypass AshBpmn.Checks.AshBpmnInteraction do
      authorize_if always()
    end

    bypass AshDecisions.Checks.AshDecisionsInteraction do
      authorize_if always()
    end

    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy always() do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
      authorize_if AshEnterprise.Security.Checks.SharedWithActor
    end
  end
end
