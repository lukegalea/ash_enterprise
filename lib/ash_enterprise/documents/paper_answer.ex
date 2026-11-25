defmodule AshEnterprise.Documents.PaperAnswer do
  @moduledoc """
  A person's answer to a question a requirement asked (R1, R8): the record of
  who answered what, on which blocked run, and the fact it admitted.

  `answer` is **self-service** and the only write. Its input is the run the
  question was asked on, the predicate and the answer; everything else comes
  from the run, never from input (`AshEnterprise.Documents.PaperAnswer.Changes.FromRun`):

    * the run is read through `PaperRun.mine` as the actor, so a person only
      answers on their own runs in their own organization — a run of another
      organization, or another member's, is not found;
    * the predicate must be one the run's kind's requirement declares and asks
      a person (`missing: :unknown`) — anything else is refused;
    * the run must have asked it: its recorded `missing_fact` problem gives the
      scope (the organization and the kind's own scope) and the subject state
      digest the answer is recorded under, and the organization in that scope
      must be the tenant's.

  In the same transaction the answer is admitted as the asked fact, at person
  grade, through `AshJudgments.Facts.Materialiser` (the facts table's one
  write path), with this row's id as the fact's `admission_id` and
  `valid_until` what the kind says for the scope (its `valid_until/1`)
  (`AshEnterprise.Documents.Paper.Interview.record/1`). A fact that cannot be
  written fails the answer.

  User-owned, never updated or destroyed: a later answer to the same question
  is a new row whose fact revises the earlier one.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Documents,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    self_service: [:answer, :mine]

  postgres do
    table "paper_answers"
    repo AshEnterprise.Repo

    references do
      reference :run, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    read :mine do
      description "The actor's own answers, newest first."
      filter expr(owner_id == ^actor(:id) and owner_type == :user)
      prepare build(sort: [inserted_at: :desc])
    end

    create :answer do
      description """
      Answer one question a requirement asked on one of your blocked runs. The
      answer is recorded as the asked fact for the run's organization and scope;
      issue the document again to continue.
      """

      accept [:run_id, :predicate, :holds]

      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
      change set_attribute(:owning_business_unit_id, actor(:owning_business_unit_id))
      change AshEnterprise.Documents.PaperAnswer.Changes.FromRun
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :predicate, :string do
      allow_nil? false
      public? true
      constraints max_length: 120
      description "The asked predicate, as the requirement's fact schema names it."
    end

    attribute :holds, :boolean do
      allow_nil? false
      public? true
      description "The person's answer."
    end

    attribute :document_kind, :string do
      allow_nil? false
      public? true
      description "The kind of the run the question was asked on."
    end

    attribute :scope, :map do
      allow_nil? false
      public? true
      description "The scope the fact is recorded in: the organization and the kind's scope."
    end

    attribute :subject_state_digest, :string do
      allow_nil? false
      public? true
      description "The keyed digest of the payload the question was asked about."
    end

    attribute :valid_until, :utc_datetime_usec do
      public? true

      description "Until when the answer holds, as the kind says for the scope; nil for no expiry."
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :run, AshEnterprise.Documents.PaperRun do
      allow_nil? false
      public? true
      attribute_writable? true
      description "The blocked run the question was asked on."
    end
  end
end
