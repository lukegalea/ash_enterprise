defmodule AshEnterprise.Documents do
  @moduledoc """
  The documents surface: issuing real documents from the host's own data
  through the paper kernel (`github.com/lukegalea/ash_paper`):

    * `AshEnterprise.Documents.PaperBinding` — what a document kind is rendered
      with, one temporal row per (organization, kind).
    * `AshEnterprise.Documents.PaperRun` — one attempt to produce a document:
      the stored bytes are the record, the render and its read-back are its two
      status axes, and the payload it rendered is sealed.
    * `AshEnterprise.Documents.PaperClause` — the wording a document may
      carry, per locale: tenant data, drafted and admitted with maker-checker,
      measured before admission for what it would change in issued documents,
      pinned by a binding, and recorded on the run with the rule that put it
      there.
    * `AshEnterprise.Documents.PaperDraft` — a rendered document waiting for a
      person (R10): approved, then issued exactly as rendered while nothing it
      was made from has moved, or marked stale and never issued.
    * `AshEnterprise.Documents.PaperAnswer` — a person's answer to a question
      a requirement asked on a blocked run (R1, R8), admitted as a person-grade
      fact so the next document in the same scope is not asked again.
    * `AshEnterprise.Documents.PaperQuestion` — computed: the questions the
      person's blocked runs are still asking, the rows of the questions surface.
    * `AshEnterprise.Documents.Paper` — the kinds the host can issue (schemas,
      the letter layout, themes) and the steps `issue` composes.

  Issuing a document is self-service: a member renders *their* data (the
  document's kind reads its own rows as them, `AshEnterprise.Documents.Paper.Kind`)
  into a PDF, and the bytes are ingested as an
  `AshEvidence.DocumentVersion` in their tenant. The run's `payload` and
  `facts` are sealed under the requester's own erasure scope, so shredding
  that person's scope shreds what the document said while the row, its hashes
  and its audit chain stay.
  """

  use Ash.Domain

  resources do
    resource AshEnterprise.Documents.PaperBinding do
      define :bind_paper, action: :bind, args: [:model_key, :purpose]
      define :rebind_paper, action: :rebind
      define :unbind_paper, action: :unbind
      define :get_paper_binding, action: :read, get_by: [:id]
      define :get_paper_binding_by_selector, action: :read, get_by: [:selector]
      define :list_paper_bindings, action: :read
    end

    resource AshEnterprise.Documents.PaperRun do
      define :issue_paper_run, action: :issue, args: [:document_kind, :subject, :title]
      define :draft_paper_run, action: :draft, args: [:document_kind, :subject, :title]
      define :issue_paper_draft, action: :issue_draft, args: [:draft_id]
      define :my_paper_runs, action: :mine
      define :get_paper_run, action: :read, get_by: [:id]
      define :list_paper_runs, action: :read
    end

    resource AshEnterprise.Documents.PaperDraft do
      define :propose_paper_draft, action: :propose
      define :record_paper_draft_check, action: :record_check
      define :mark_paper_draft_stale, action: :mark_stale
      define :approve_paper_draft, action: :approve
      define :reject_paper_draft, action: :reject
      define :apply_paper_draft, action: :apply
      define :supersede_paper_draft, action: :supersede
      define :record_paper_draft_outcome, action: :record_issue_outcome
      define :get_paper_draft, action: :read, get_by: [:id]
      define :list_paper_drafts, action: :read
    end

    resource AshEnterprise.Documents.PaperAnswer do
      define :answer_paper_question, action: :answer
      define :my_paper_answers, action: :mine
    end

    resource AshEnterprise.Documents.PaperQuestion do
      define :open_paper_questions, action: :open
      define :confirm_paper_question, action: :confirm, args: [:record_id]
      define :deny_paper_question, action: :deny, args: [:record_id]
    end

    resource AshEnterprise.Documents.PaperClause do
      define :draft_paper_clause, action: :draft, args: [:key, :locale]
      define :measure_paper_clause_impact, action: :measure_impact
      define :admit_paper_clause, action: :admit
      define :paper_clause_impact_changes, action: :impact_changes
      define :retire_paper_clause, action: :retire
      define :get_paper_clause, action: :read, get_by: [:id]
      define :list_paper_clauses, action: :read
    end
  end
end
