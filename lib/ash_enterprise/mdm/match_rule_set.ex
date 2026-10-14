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

  policies do
    # `policies?: false` + explicit set (the HumanVerdict drill): the
    # person-only gate must precede the grant union, and the inherited set
    # opens with bypasses that would let a system actor reach :activate.
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
      authorize_if AshEnterprise.Security.Checks.HierarchyGrant
    end
  end

  code_interface do
    define :by_id, action: :read, get_by: [:id], not_found_error?: false
  end
end
