defmodule AshEnterprise.Documents.PaperRun do
  @moduledoc """
  One attempt to produce a document: `AshPaper.Fragment.Run` on the platform
  base, in table `paper_runs`, tenant-scoped in the
  `AshEnterprise.Documents` domain.

  The fragment supplies the contract and its two independent status axes:
  `render_status` (`:pending` → `:rendered`/`:failed`) and `read_back_status`
  (`:not_run` → `:passed`/`:failed`/`:unmeasured`). A run whose read-back
  never ran stays `:not_run`, which is visible and is not a pass. The stored
  bytes are the record: the issued PDF is an `AshEvidence.DocumentVersion`
  (content-addressed, so the same bytes are one row) and the run carries its
  `output_digest`.

  ## Who may do what (ADR 0059, ADR 0052)

    * `issue` is **self-service**: any active member renders a document of
      their own tenant's data, read by the kind as them. It composes the whole
      pipeline — source, payload,
      binding pin, render with explicit limits, ingest, read-back — and is
      the only write path a person reaches.
    * The fragment's axes (`start`, `record_render`,
      `record_render_failure`, `record_read_back`) are **machinery-only**: a
      person never writes a run's axes. `issue` performs them as its own
      bookkeeping (`authorize?: false`, named with the actor), which is the
      same bound as `AshEnterprise.Planning.Actions.CancelOwnRun`: the
      self-service declaration is the grant, the pipeline is its bounds.
    * `draft` and `issue_draft` are **self-service** too, the governed path
      (R10): `draft` runs the same pipeline at stage `:draft` and proposes an
      `AshEnterprise.Documents.PaperDraft`; a person approves it; `issue_draft`
      issues exactly the approved bytes while nothing they were made from has
      moved. `promote_draft`, the stage move, is **machinery-only**: only the
      draft's `apply` performs it.

  ## Stage

  `stage` is `:issued` (the default, so a one-step `issue` keeps its meaning)
  or `:draft`. A draft run's bytes are stored and read back, but it is not an
  issued document until its approved draft is applied; `issued?` says whether
  a run is one.

  ## Ownership and sealing

  User-owned: `issue` stamps the requester as `owner_id` and opens (or
  finds) their own erasure scope. `payload`, `facts` and `payload_hash_key`
  — the display strings and typed values the document stated, and the
  32-byte secret its payload hash was keyed with — are sealed under the
  scope of the person the document is about when its kind names one
  (`sealing_scope/2`, `AshEnterprise.Documents.Paper.SealingScope`), and
  under the requester's own otherwise
  (`AshEnterprise.Erasure.Changes.SealUnderScope`), so the audit
  event of every write carries ciphertext only, and shredding that
  scope makes all three unreadable while the row, its hashes and its audit
  chain stay. A run is never destroyed (`archival?: false`, no destroy
  action).

  The issued bytes are not sealed, so the shred destroys them: the run's
  `document_version_id` (the kernel's field) names its
  `AshEvidence.DocumentVersion`, and shredding the scope destroys that version
  and its derived text unless a run in a living scope still references the
  same content-addressed bytes; the run's reference is released either way
  (`AshEnterprise.Documents.Paper.Changes.ShredDocuments`).

  ## The binding pin

  `paper_binding_id` names the binding the render used **with no database
  foreign key**: the binding's key is `(id, valid_at)`, which an ordinary
  table cannot reference (ADR 0049). The binding's hashes are copied into
  the run's `snapshot` (`AshPaper.Snapshot`) before the first render, so a
  run that already rendered never resolves its binding live: a replay reads
  the snapshot, and a binding rebound after the fact cannot change what a
  past run says it used. The snapshot's payload hash is keyed with a fresh
  32-byte secret stored beside it in `payload_hash_key` — sealed under the
  same scope, never in the snapshot, which holds hashes and references
  only — so an amount or a date cannot be brute-forced out of the hash
  after the scope's key is shredded.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Documents,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:issue, :draft, :issue_draft, :mine],
    machinery_only: [
      :start,
      :record_render,
      :record_render_failure,
      :record_read_back,
      :promote_draft,
      :release_document_version
    ],
    extra_extensions: [AshCloak],
    fragments: [AshPaper.Fragment.Run]

  postgres do
    table "paper_runs"
    repo AshEnterprise.Repo

    references do
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:payload, :facts, :payload_hash_key]
    encrypt_nil?(false)
  end

  changes do
    change {AshEnterprise.Planning.Changes.ScopeAndOwner, from: :requester}, on: [:create]

    change {AshEnterprise.Erasure.Changes.SealUnderScope,
            fields: [:payload, :facts, :payload_hash_key]},
           on: [:create, :update]
  end

  actions do
    read :mine do
      description "The actor's own runs, newest first."
      filter expr(owner_id == ^actor(:id) and owner_type == :user)
      prepare build(sort: [created_on: :desc])
    end

    action :issue, :struct do
      description """
      Render one document for the actor's tenant: read the kind's rows for the
      subject as the actor, build the payload, pin the binding, render with
      explicit limits, ingest the bytes, read them back.
      """

      constraints instance_of: __MODULE__

      argument :document_kind, :string do
        allow_nil? false
        constraints match: ~r/\A[a-z][a-z0-9_]*\z/
      end

      argument :subject, :map do
        default %{}

        description """
        The kind's subject: which of its rows the document is about (a period, a
        record id). The kind reads those rows itself, as the actor; no value is
        taken from the caller.
        """
      end

      argument :title, :string do
        allow_nil? false
        constraints trim?: true, min_length: 1
      end

      run AshEnterprise.Documents.Paper.Actions.Issue
    end

    action :draft, :struct do
      description """
      Render one document for the actor's tenant as a draft: the same pipeline as
      `issue`, recorded at stage `:draft`, with a `PaperDraft` proposed for a
      person to approve and its check recorded from the read-back.
      """

      constraints instance_of: AshEnterprise.Documents.PaperDraft

      argument :document_kind, :string do
        allow_nil? false
        constraints match: ~r/\A[a-z][a-z0-9_]*\z/
      end

      argument :subject, :map do
        default %{}

        description """
        The kind's subject: which of its rows the document is about (a period, a
        record id). The kind reads those rows itself, as the actor; no value is
        taken from the caller.
        """
      end

      argument :title, :string do
        allow_nil? false
        constraints trim?: true, min_length: 1
      end

      run AshEnterprise.Documents.Paper.Actions.Draft
    end

    action :issue_draft, :struct do
      description """
      Issue an approved draft exactly as rendered, after recomputing what it was
      made from (its kind's rows re-read as the actor): anything moved marks it
      stale and refuses.
      """

      constraints instance_of: __MODULE__

      argument :draft_id, :uuid, allow_nil?: false

      run AshEnterprise.Documents.Paper.Actions.IssueDraft
    end

    update :promote_draft do
      description "The run's approved draft was applied: the run is issued, its bytes unchanged."
      accept []
      require_atomic? false

      validate attribute_equals(:stage, :draft),
        message: "only a draft run is issued from its draft"

      validate attribute_equals(:render_status, :rendered),
        message: "only a rendered run is issued"

      validate attribute_equals(:read_back_status, :passed),
        message: "only a run whose read-back passed is issued"

      change set_attribute(:stage, :issued)
    end

    update :release_document_version do
      description """
      The run's scope was shredded: it no longer references its stored bytes,
      which were destroyed unless a run in a living scope still references them
      (`AshEnterprise.Documents.Paper.Changes.ShredDocuments`).
      """

      accept []
      change set_attribute(:document_version_id, nil)
    end
  end

  attributes do
    attribute :stage, :atom do
      allow_nil? false
      default :issued
      public? true
      constraints one_of: [:issued, :draft]

      description """
      `:issued` for a one-step issue and for a draft run whose approved draft was
      applied; `:draft` for a draft's rendering, which is never an issued document.
      """
    end

    attribute :world, :atom do
      allow_nil? false
      default :operational
      constraints one_of: [:operational]

      description """
      Always `:operational`. A draft copies its run's world when it is proposed
      (`AshPlanning.Fragment.Candidate`), and a rendered document is never a scenario.
      """
    end

    attribute :paper_binding_id, :uuid do
      public? true
      description "The binding the render was pinned against; no foreign key, see the moduledoc."
    end
  end

  calculations do
    calculate :issued?,
              :boolean,
              expr(stage == :issued and render_status == :rendered) do
      public? true
      description "An issued document: rendered, and not a draft waiting for a person."
    end
  end

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      description "The scope `payload` and `facts` are sealed under."
    end
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    keep(:encrypted_facts,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )

    keep(:encrypted_payload,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )

    keep(:encrypted_payload_hash_key,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )
  end
end
