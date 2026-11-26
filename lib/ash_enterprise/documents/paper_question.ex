defmodule AshEnterprise.Documents.PaperQuestion do
  @moduledoc """
  The questions a requirement is still asking the signed-in person, one row
  per fact one of their blocked runs is missing (R1). Computed, never stored:
  the questions surface (`AshEnterpriseWeb.A2ui.PaperQuestionsUI`,
  served under the app) reads `open`, and each row's Yes or No is
  `confirm` or `deny`.

  Nobody designs this form. The rows are the `missing_fact` problems the
  interview recorded on the person's own blocked runs
  (`AshEnterprise.Documents.Paper.Interview`), read through `PaperRun.mine` as
  the person, the newest run's question kept per (predicate, scope), and
  shown only while the answer as it stands now is still unknown — so an
  answered question leaves the list on the next read, and issuing the document
  again records the next round's questions, if any. The reason column says why
  it is asked: not answered yet, the data changed since, the answer expired,
  or an answer below person grade.

  `confirm` and `deny` take the row's id (`"<run id>/<predicate>"`) and create
  an `AshEnterprise.Documents.PaperAnswer` as the actor, which re-reads the run
  as them and refuses anything it did not ask; they scope themselves to the
  actor by construction.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Documents,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:open, :confirm, :deny]

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "`<run id>/<predicate>`: what `confirm` and `deny` answer."
    end

    attribute :run_id, :uuid, public?: true, description: "The blocked run that asked."
    attribute :document_kind, :string, public?: true, description: "The kind of document."

    attribute :about, :string,
      public?: true,
      description: "What the answer is for: the values of the kind's scope (a period, say)."

    attribute :predicate, :string, public?: true, description: "The asked fact."
    attribute :question, :string, public?: true, description: "The fact's own description."

    attribute :message, :string,
      public?: true,
      description: "The message of the rule that asks."

    attribute :evidence, :string,
      public?: true,
      description: "What the rule says would satisfy it."

    attribute :reason, :string, public?: true, description: "Why it is asked now."
  end

  actions do
    read :open do
      description "The questions your blocked documents are still asking, newest first."
      manual AshEnterprise.Documents.PaperQuestion.Open
    end

    action :confirm do
      description "Answer yes to one open question."
      argument :record_id, :string, allow_nil?: false, public?: true
      run {AshEnterprise.Documents.PaperQuestion.Answer, holds: true}
    end

    action :deny do
      description "Answer no to one open question."
      argument :record_id, :string, allow_nil?: false, public?: true
      run {AshEnterprise.Documents.PaperQuestion.Answer, holds: false}
    end
  end
end
