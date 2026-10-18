defmodule AshEnterprise.Mdm.MatchCandidate do
  @moduledoc """
  One (staged record, golden record) candidate pair with its score and
  per-rule explanation. Candidate generation runs as a system actor
  (ADR 0017's first sharp edge); the REVIEW SURFACE is filtered separately
  — a steward never learns of a candidate they cannot read, nor of one
  whose golden they cannot read (`:review_queue`), and cannot decide a
  candidate whose golden they cannot read (`:confirm`, `:reject` and
  `:escalate` all refuse it), whichever door the decision comes through.

  Confirming or rejecting a review-banded candidate is a person's decision
  (ADR 0054): the policy set opens with the person gate, so a system actor
  cannot drive a merge through the queue even via the engine bypasses it
  keeps for its own machinery. The queue's confirm/reject are the stable
  seam a BPMN HumanTask completion maps onto — the queue (S1-62) is the
  work surface, these actions are the acts.

  ## The steward surface (`AshEnterpriseWeb.A2ui.MdmStewardUI`)

  The surface reads `:review_queue` and shows the staged-vs-golden diff
  through the calculations below, which load the staged row and the golden
  through `staged_record` and `golden` **under the reader's policies**: a
  steward who may not read a golden (Person is owner-only) sees its side of
  the diff empty, never its values.

  Its buttons are the verdicts themselves — `:confirm`, `:reject` and
  `:escalate`, labelled Confirm match, Reject match and Mark unsure on the
  surface — run as the clicking person, so the person gate and the update
  grant decide. A steward-decision task decides the same updates
  (`AshEnterprise.Mdm.StewardTask`), and the verdict completes that task as
  the person in the same transaction (`AshEnterprise.Mdm.Changes.StewardVerdict`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Mdm,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    policies?: false

  use AshMdm.Resources, {:match_candidate, []}

  alias AshEnterprise.Platform.Calculations.RelatedField

  postgres do
    table "mdm_match_candidates"
    repo AshEnterprise.Repo

    references do
      # Display relationships over the package's own id attributes: no
      # foreign key. `golden_id` is polymorphic by `golden_resource`, and the
      # pipeline's row order is the package's business, not the schema's.
      reference :staged_record, ignore?: true
      reference :golden, ignore?: true
    end
  end

  relationships do
    belongs_to :staged_record, AshEnterprise.Mdm.StagedRecord do
      source_attribute :staged_record_id
      define_attribute? false
      public? true
      description "The staged row this candidate would merge."
    end

    # Person is the only golden resource today (the mappings' allowlist);
    # a second golden resource would add its own relationship here.
    belongs_to :golden, AshEnterprise.Canonical.Person do
      source_attribute :golden_id
      define_attribute? false
      public? true
      description "The golden record the staged row would merge into."
    end
  end

  calculations do
    # The staged-vs-golden diff. Each side is read through its relationship
    # under the reader's policies (`RelatedField` loads it; an expression
    # through the relationship would join past them): a reader who may not
    # read the staged row or the golden sees that side empty.
    calculate :staged_name,
              :string,
              {RelatedField, relationship: :staged_record, field: :mapped, keys: ["name"]} do
      public? true
      description "The staged row's mapped name."
    end

    calculate :staged_email,
              :string,
              {RelatedField, relationship: :staged_record, field: :mapped, keys: ["email"]} do
      public? true
      description "The staged row's mapped email."
    end

    calculate :staged_label,
              :string,
              {RelatedField,
               relationship: :staged_record,
               field: :mapped,
               keys: ["name", "email"],
               default: "Staged record"} do
      public? true
      description "The staged row by name, else email."
    end

    calculate :staged_batch_label, :string, expr("Import batch") do
      public? true
      description "The link text for the import batch the staged row came in."
    end

    calculate :golden_name, :string, {RelatedField, relationship: :golden, field: :name} do
      public? true
      description "The golden record's name."
    end

    calculate :golden_email, :string, {RelatedField, relationship: :golden, field: :email} do
      public? true
      description "The golden record's email."
    end

    calculate :golden_label,
              :string,
              {AshEnterprise.Canonical.Calculations.PersonLabel, relationship: :golden} do
      public? true
      description "The golden record by name, else email."
    end

    calculate :name_survivor, :string, {AshEnterprise.Mdm.Calculations.Survivor, field: :name} do
      public? true
      description "Whose name survives a confirm."
    end

    calculate :email_survivor,
              :string,
              {AshEnterprise.Mdm.Calculations.Survivor, field: :email} do
      public? true
      description "Whose email survives a confirm."
    end

    calculate :explanation_text,
              :string,
              AshEnterprise.Mdm.Calculations.ExplanationText do
      public? true
      description "The matcher's per-rule explanation, one rule per line."
    end

    calculate :waiting_since,
              :string,
              {AshEnterprise.Platform.Calculations.LocalStamp,
               field: :created_on, relative?: true} do
      public? true
      description "When the candidate entered the queue, on the operator's wall clock."
    end
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

    # The machine's own writes: banding and pipeline states (`:update`) and
    # the verdict pointers stamped after a gated decision
    # (`:record_verdict_ref`). The platform calls them as a system actor (or
    # with authorization off), which the bypasses above admit; a person's
    # write grant on candidates covers the verdicts, never these. A positive
    # gate, like the person gate above, so the union below stays additive.
    policy action([:update, :record_verdict_ref]) do
      authorize_if AshEnterprise.Security.Checks.SystemActor
    end

    policy always() do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
      authorize_if AshEnterprise.Security.Checks.SharedWithActor
      authorize_if AshEnterprise.Security.Checks.HierarchyGrant
      authorize_if AshEnterprise.Security.Checks.SelfService
    end
  end

  actions do
    # The golden must be readable by the reader (ADR 0017's existence rule,
    # ADR 0054 §"Does it consume ActorContext?" 1): candidates are generated
    # as a system actor, so a pending candidate for a golden the steward may
    # not read would tell them that golden exists. An *unrelated* exists, on
    # purpose: Ash authorizes it with Person's primary read (its policies,
    # from the reader's ActorContext), where `exists(golden, ...)` through
    # the relationship joins past them.
    read :review_queue do
      description "The steward's queue: review-banded candidates still pending whose golden the reader may read, oldest first."

      filter expr(
               band == :review and status == :pending and
                 exists(AshEnterprise.Canonical.Person, id == parent(golden_id))
             )

      prepare build(sort: [created_on: :asc, id: :asc])
    end

    update :confirm do
      description "A steward confirms the match: the staged record merges into the golden record."
      accept []
      validate attribute_equals(:status, :pending)
      # Nobody confirms a merge into a record they cannot see: the queue does
      # not list such a candidate, and a confirm by id is refused the same way.
      validate AshEnterprise.Mdm.Validations.GoldenReadable
      require_atomic? false

      change set_attribute(:status, :confirmed)
      change AshEnterprise.Mdm.Changes.StewardVerdict
    end

    update :reject do
      description "A steward rejects the match: the staged record stands alone as a new golden record."
      accept []
      validate attribute_equals(:status, :pending)
      # Deciding "not that golden" is a judgment about the golden: nobody
      # makes it about a record they cannot see.
      validate AshEnterprise.Mdm.Validations.GoldenReadable
      require_atomic? false

      change set_attribute(:status, :rejected)
      change AshEnterprise.Mdm.Changes.StewardVerdict
    end

    update :escalate do
      description "A steward cannot decide: the verdict is recorded, the candidate stays pending."
      accept []
      validate attribute_equals(:status, :pending)
      validate AshEnterprise.Mdm.Validations.GoldenReadable
      require_atomic? false

      change AshEnterprise.Mdm.Changes.StewardEscalation
    end
  end
end
