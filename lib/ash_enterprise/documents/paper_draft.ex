defmodule AshEnterprise.Documents.PaperDraft do
  @moduledoc """
  A rendered document waiting for a person (R10): `AshPlanning.Fragment.Candidate`
  on the platform base, in table `paper_drafts`. `PaperRun.draft` renders a run at
  stage `:draft` and proposes one draft for it (index 0); a person approves it, and
  `PaperRun.issue_draft` issues exactly the approved bytes, only while nothing the
  draft was made from has moved.

  The fragment supplies the axes and their guards: `check_status` (the run's
  read-back: `:passed` is `:correct`, `:failed` is `:incorrect`, anything that did
  not measure is `:incomplete`), `freshness` and `disposition`. `approve` and
  `apply` need a `:correct` check and a `:current` draft, so a draft whose
  read-back failed or never measured can never be approved, and a stale one can
  never be applied. The fragment never detects staleness; `issue_draft` does, by
  recomputing the draft's fingerprint against the current source.

  ## Who may do what (ADR 0059)

    * `propose`, `record_check`, `mark_stale`, `supersede` and
      `record_issue_outcome` are **machinery-only**: the draft and issue pipelines
      write them as the `oban` system actor, and no grant row reaches them.
    * `approve`, `reject` and `apply` are **human-only**: only the calling
      person's own grants authorize one. `apply` moves the run to `:issued`
      (`AshEnterprise.Documents.Paper.Changes.IssueDraftRun`) in the same
      transaction, with no re-render.
    * `read` is a self-service read bounded to the actor's own drafts.

  ## The fingerprint

  `assignments` holds the draft's fingerprint as canonical JSON: the binding id and
  the hash of its selection, the clause pins, the decision definitions used (key,
  version, content hash), each decision's include and matched rule ids, the payload
  hash (keyed with the run's own sealed `payload_hash_key`), the title the payload
  was built with and the output digest. It is sealed under the run's erasure scope;
  once that scope is shredded the draft can no longer be checked, so it can no
  longer be issued.

  ## Ownership

  User-owned: `propose` takes the owner and the erasure scope from its run
  (`AshEnterprise.Planning.Changes.ScopeAndOwner`, `from: :run`), never from input.
  Rows are never destroyed. Every `issue_draft` attempt is appended to
  `issue_outcomes` — issued, stale (with what moved) or refused (with why) — so
  nothing an issue tried is silent.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Documents,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:read],
    machinery_only: [:propose, :record_check, :mark_stale, :supersede, :record_issue_outcome],
    human_only: [:approve, :reject, :apply],
    extra_extensions: [AshCloak],
    fragments: [AshPlanning.Fragment.Candidate]

  alias AshEnterprise.Documents.Paper.Changes

  postgres do
    table "paper_drafts"
    repo AshEnterprise.Repo

    references do
      reference :run, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:assignments]
    encrypt_nil?(false)
  end

  changes do
    change {AshEnterprise.Planning.Changes.ScopeAndOwner,
            from: :run, resource: AshEnterprise.Documents.PaperRun},
           on: [:create]

    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:assignments]},
      on: [:create, :update]

    change Changes.IssueDraftRun, on: [:update], where: action_is(:apply)

    # An `issue_draft` outcome rides the write it describes (`apply`, `mark_stale`)
    # in the `context:` option, so the two land together or not at all; a refusal
    # that writes nothing else is `record_issue_outcome`.
    change AshEnterprise.Documents.PaperDraft.Changes.AppendOutcome, on: [:update]
  end

  actions do
    update :record_issue_outcome do
      description "Append what one `issue_draft` attempt came to: issued, stale or refused."
      accept []
      require_atomic? false

      argument :outcome, :map, allow_nil?: false
    end
  end

  attributes do
    attribute :issue_outcomes, {:array, :map} do
      allow_nil? false
      default []
      public? true

      description """
      Every `issue_draft` attempt, oldest first: `outcome` (`"issued"`, `"stale"` or
      `"refused"`), `moved` (what differed from the fingerprint), `reason` and
      `at`. Structural names only, never a document's content or who acted
      (the audit trail records that).
      """
    end
  end

  relationships do
    belongs_to :run, AshEnterprise.Documents.PaperRun do
      public? true
      define_attribute? false
      description "The draft-stage run that rendered the bytes."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      description "The run's scope, which `assignments` is sealed under."
    end
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    keep(:encrypted_assignments,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )
  end
end
