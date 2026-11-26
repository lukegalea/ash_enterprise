defmodule AshEnterprise.Mdm.MatchRuleProposal do
  @moduledoc """
  A proposed new version of a tenant's match rules, learned from what its
  stewards already decided (S1-84, ADR 0047: only a person adopts).

  `propose` (`AshEnterprise.Mdm.Changes.ProposeMatchRules`) reads the active
  rule set and every pair a steward confirmed or rejected, asks
  `AshMdm.Tuning` for new rule weights, and writes them as a draft successor
  rule set. Before anyone can act on it, the proposal replays those verdicts
  under both versions through the tenant's band table
  (`AshEnterprise.Mdm.MatchReplay`) and keeps what it found:

    * `replay`: how many verdicts were replayed or skipped, how many pairs
      would change band and in which direction, and per version its bands,
      its agreement with the stewards and its precision and recall;
    * `changed_pairs`: each pair whose band would move;
    * `flips`: how many of those moves would undo a steward's decision, a
      confirmed match now omitted or a rejected one now admitted. A proposal
      with flips is `flagged`.

  The replay runs over the same verdicts the weights were learned from, so it
  shows what the proposal would change, not a lift on held-out data (ADR 0047
  §7). The proposal keeps its lineage: the rule set it came from, the learner
  and its version, and a digest of the verdicts it saw. Once activated, the new
  rules have a new content hash and their bands are earned again by
  calibration.

  Nothing changes matching until a person activates it. `activate` is a
  person's act, gated by the person check and a grant, and it activates the
  draft through `MatchRuleSet.activate` as that person, so the rule set's own
  gate and ash_mdm's refusals apply; a refusal there refuses the proposal. A
  proposal whose replayed rule set is no longer active is stale and cannot be
  activated (`AshEnterprise.Mdm.Changes.ActivateProposedRules`). `reject`
  declines it; its draft stays a draft and scores nothing.

  The surface is `AshEnterpriseWeb.A2ui.MdmMatchRuleProposalUI`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    policies?: false

  postgres do
    table "mdm_match_rule_proposals"
    repo AshEnterprise.Repo
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml). The
  # replay holds candidate ids, bands, scores and counts, and the tuning report rule
  # names and weights: nothing a person wrote and no record's values.
  greenmask do
    keep(:tuning, because: "rule names, weights and rates; no record values")
    keep(:replay, because: "counts, bands and ratios over steward verdicts; no record values")

    keep(:changed_pairs,
      because: "candidate ids with their verdict, bands and scores; no record values"
    )
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :proposed
      constraints one_of: [:proposed, :activated, :rejected]
    end

    attribute :golden_resource, :string do
      allow_nil? false
      public? true
      constraints max_length: 256
      description "The rule set's golden resource key (MatchRuleSet.golden_resource)."
    end

    attribute :base_rule_set_id, :uuid do
      allow_nil? false
      public? true
      description "The active rule set the proposal was learned from and replayed against."
    end

    attribute :rule_set_id, :uuid do
      allow_nil? false
      public? true
      description "The draft successor rule set holding the proposed rules."
    end

    attribute :band_table_id, :uuid do
      allow_nil? false
      public? true
      description "The mdm:match_bands definition the replay banded through."
    end

    attribute :proposer, :string do
      allow_nil? false
      public? true
      description "The learner that drafted the rules and its version (ADR 0047 lineage)."
    end

    attribute :verdicts_digest, :string do
      allow_nil? false
      public? true

      description "SHA-256 over the sorted ids of the verdicts the proposal learned from and replayed."
    end

    attribute :tuning, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description "AshMdm.Tuning's report: per rule, its status, weights before and after, and m and u."
    end

    attribute :replay, :map do
      allow_nil? false
      public? true

      description "The replay's counts and, per version, its bands, agreement, precision and recall."
    end

    attribute :changed_pairs, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description "Each replayed pair whose band would move: candidate id, verdict, bands and scores."
    end

    attribute :flips, :integer do
      allow_nil? false
      public? true
      default 0
      description "Changed pairs that would land against the steward's verdict."
    end
  end

  calculations do
    calculate :flagged, :boolean, expr(flips > 0) do
      public? true
      description "The proposal would undo at least one steward decision."
    end

    calculate :replay_summary,
              :string,
              {AshEnterprise.Mdm.Calculations.ReplayText, part: :summary} do
      public? true

      description "The replay in a few lines: changes, flips, and each version against the stewards."
    end

    calculate :changed_pairs_text,
              :string,
              {AshEnterprise.Mdm.Calculations.ReplayText, part: :changed_pairs} do
      public? true
      description "The pairs whose band would move, one per line."
    end

    calculate :tuning_text,
              :string,
              {AshEnterprise.Mdm.Calculations.ReplayText, part: :tuning} do
      public? true
      description "Each rule's weight before and after, one per line."
    end
  end

  policies do
    # Adopting or declining a proposal is a person's act (ADR 0047), so the
    # person gate precedes the bypasses: no system actor, agent or engine
    # reaches these actions, and a person still needs the update grant below.
    policy action([:activate, :reject]) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    # Proposing is machinery the platform may run on its own.
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy always() do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
      authorize_if AshEnterprise.Security.Checks.SharedWithActor
      authorize_if AshEnterprise.Security.Checks.HierarchyGrant
    end
  end

  actions do
    read :read do
      primary? true
    end

    create :propose do
      description "Proposes new match-rule weights from the steward verdicts, replayed over them."
      accept [:golden_resource]
      change AshEnterprise.Mdm.Changes.ProposeMatchRules
    end

    update :activate do
      description "A person adopts the proposal: its rule set becomes the active version."
      accept []
      require_atomic? false

      validate attribute_equals(:status, :proposed) do
        message "only a proposed rule change can be activated"
      end

      change AshEnterprise.Mdm.Changes.ActivateProposedRules
      change set_attribute(:status, :activated)
    end

    update :reject do
      description "A person declines the proposal: the active rules stay as they are."
      accept []

      validate attribute_equals(:status, :proposed) do
        message "only a proposed rule change can be rejected"
      end

      change set_attribute(:status, :rejected)
    end
  end
end
