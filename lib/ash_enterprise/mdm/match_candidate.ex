defmodule AshEnterprise.Mdm.MatchCandidate do
  @moduledoc """
  One (staged record, golden record) candidate pair with its score and
  per-rule explanation. Candidate generation runs as a system actor
  (ADR 0017's first sharp edge); the REVIEW SURFACE is filtered separately
  — a steward never learns of a candidate they cannot read.

  Confirming or rejecting a review-banded candidate is a person's decision
  (ADR 0050): the policy set opens with the person gate, so a system actor
  cannot drive a merge through the queue even via the engine bypasses it
  keeps for its own machinery. The queue's confirm/reject are the stable
  seam a BPMN HumanTask completion maps onto — the queue (S1-62) is the
  work surface, these actions are the acts.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    policies?: false

  use AshMdm.Resources, {:match_candidate, []}

  postgres do
    table "mdm_match_candidates"
    repo AshEnterprise.Repo
  end

  policies do
    # The steward's verdict is a person's act — same gate as mapping
    # activation: positive personhood, not "not a system actor", so a
    # future actor kind fails closed.
    policy action([:confirm, :reject, :escalate]) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    # Machinery reads and generates; the engine bypasses stay for the
    # platform's own interactions.
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

  actions do
    update :confirm do
      description "A steward confirms the match: the staged record merges into the golden record."
      accept []
      validate attribute_equals(:status, :pending)
      require_atomic? false

      change set_attribute(:status, :confirmed)
      change AshEnterprise.Mdm.Changes.StewardVerdict
    end

    update :reject do
      description "A steward rejects the match: the staged record stands alone as a new golden record."
      accept []
      validate attribute_equals(:status, :pending)
      require_atomic? false

      change set_attribute(:status, :rejected)
      change AshEnterprise.Mdm.Changes.StewardVerdict
    end

    update :escalate do
      description "A steward cannot decide: the verdict is recorded, the candidate stays pending."
      accept []
      validate attribute_equals(:status, :pending)
      require_atomic? false

      change AshEnterprise.Mdm.Changes.StewardEscalation
    end
  end
end
