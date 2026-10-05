defmodule AshEnterprise.SystemOne.FilterExecution do
  @moduledoc """
  The audit row for one executed filter (S1-65; S1-56 §3.5): the proposal
  is auditable like any other query, so every run records the FINAL
  (post-edit) CQL2 document, the compiled plan, and the three-partition
  counts — with the link back to the translation observation that seeded
  the chain (the wire question hash) and the NL digest.

  The chain closes S1-56 §3.5's provenance requirement on the Basic slice:
  proposal → (person edits, versions) → approval → execution → the executed
  document and plan are queryable data on the platform base, AshEvents-
  audited like every other write, attributed to the acting tenant and
  correlation group.

  `document` and `plan` are the query's own record — envelope-class
  structure over declared vocabulary. The NL digest travels for the
  seed link; the NL text itself stays on the (payload-class) proposal
  and never lands here.
  """

  @type t :: %__MODULE__{}

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false

  postgres do
    table "system_one_filter_executions"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :proposal_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "The approved proposal version that ran."

    attribute :proposal_version, :integer,
      allow_nil?: false,
      public?: true,
      description: "The version number of the proposal that ran."

    attribute :document, :map,
      allow_nil?: false,
      public?: true,
      description: "The FINAL (post-edit) Basic CQL2 document exactly as executed."

    attribute :plan, :map,
      allow_nil?: false,
      public?: true,
      description:
        "The compiled plan: strategy, referenced predicates, operators, request-time scope and minimum admission grade."

    attribute :in_count, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      description: "Subjects the document admits (evaluation TRUE)."

    attribute :out_count, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      description: "Subjects the document excludes with data (evaluation FALSE)."

    attribute :unknown_count, :integer,
      allow_nil?: false,
      default: 0,
      public?: true,
      description:
        "Subjects the document cannot decide (evaluation UNKNOWN) — the assess action's input."

    attribute :min_grade, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:grant, :person]],
      description: "The request-time minimum admission grade (Q19; search default: grant)."

    attribute :scope, :map,
      allow_nil?: true,
      public?: true,
      description:
        "The request-time scope the facts were folded under (exact match; nil = the subject alone)."

    attribute :wire_question_hash, :string,
      allow_nil?: false,
      public?: true,
      description:
        "The translation observation's digest (the proposal's wire question hash) — the seed link."

    attribute :nl_digest, :string,
      allow_nil?: false,
      public?: true,
      description:
        "Digest of the natural-language seed text (the text itself stays on the proposal)."

    create_timestamp :ran_at
  end

  actions do
    defaults [:read]

    create :execute do
      description """
      Records one run. Every field is an input — the query already ran as
      the actor when this create was made, and replay rebuilds the row
      without re-executing anything (the ledger's §6.1 discipline).
      """

      accept [
        :proposal_id,
        :proposal_version,
        :document,
        :plan,
        :in_count,
        :out_count,
        :unknown_count,
        :min_grade,
        :scope,
        :wire_question_hash,
        :nl_digest
      ]
    end
  end

  policies do
    # A run is an explicit act: a person runs their own search, and system
    # actors (tooling, ADR 0045 advisory posture) may too. Nothing here is
    # reachable from a read path — executions are written only by
    # Filter.Runner, which refuses anything but an approved proposal.
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
