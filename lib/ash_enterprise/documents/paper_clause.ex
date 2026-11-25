defmodule AshEnterprise.Documents.PaperClause do
  @moduledoc """
  One wording clause a document may carry, per locale: tenant data, drafted and
  admitted by people, in the table `paper_clauses`.

  A clause is `runs`: literal `"text"` runs and `"hole"` runs naming a payload
  field (`AshPaper.Clause` renders only what the payload holds). `content_hash`
  is `AshPaper.Clause.hash/1` of the same runs, computed by a change and never
  accepted as input, so what a binding pins and what a run records is the
  wording itself. `to_kernel/1` converts a row to the kernel's
  `%AshPaper.Clause{}`, which `AshPaper.Binding.selection/4` pins and
  `AshPaper.Clause.resolve/3` fills.

  ## Lifecycle

      draft ── admit ──▶ admitted ── retire ──▶ retired

  `AshStateMachine` drives `status`, as it does for the host's other versioned
  records (`AshEnterprise.Execution.ReleaseManifest`,
  `AshEnterprise.Quality.Suite`). `draft` creates at the next version for
  `(key, locale)`; `admit` moves a draft to `:admitted` and stamps
  `admitted_by_id`; `retire` closes an admitted version. `admit` is
  maker-checker: the person who drafted a clause may not admit it — a
  validation on the action, never a `forbid_if` on rows.

  ## What admitting would change (R4)

  Before a checker admits a draft, a person runs `measure_impact`: the
  tenant's recent issued documents that carry the clause key are rendered
  again with the draft in its place and compared block by block
  (`AshEnterprise.Documents.Paper.Impact`). The report is stored on the draft
  as `impact_report`, keyed by its content hash, each document's text sealed
  under that document's own erasure scope. `admit` refuses unless that report
  exists for exactly this version and no document in it failed
  (`AshEnterprise.Documents.Paper.Validations.ImpactMeasured`).
  `impact_summary` says where the report stands; `impact_changes` lists the
  affected documents with their before and after text.

  Organization-owned configuration, like `AshEnterprise.Documents.PaperBinding`:
  it carries no owner and never soft-deletes (`archival?: false`) — retiring a
  version is how wording leaves circulation, and history stays readable.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Documents,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    extra_extensions: [AshStateMachine]

  alias AshEnterprise.Documents.PaperClause.Validations

  postgres do
    table "paper_clauses"
    repo AshEnterprise.Repo
  end

  state_machine do
    state_attribute :status
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :admit, from: :draft, to: :admitted
      transition :retire, from: :admitted, to: :retired
    end
  end

  identities do
    identity :unique_key_locale_version, [:key, :locale, :version]
  end

  actions do
    read :read do
      primary? true
    end

    create :draft do
      description "Draft the next version of a clause for `(key, locale)`."
      accept [:key, :locale, :runs]

      validate Validations.WellFormedRuns
      change AshEnterprise.Documents.PaperClause.Changes.AssignVersion
      change AshEnterprise.Documents.PaperClause.Changes.HashRuns
    end

    update :admit do
      description """
      Admit a draft: it becomes the version bindings may pin. Maker-checker —
      the drafter may not admit their own wording.
      """

      accept []
      require_atomic? false

      validate Validations.DifferentDrafter
      validate AshEnterprise.Documents.Paper.Validations.ImpactMeasured
      change transition_state(:admitted)
      change AshEnterprise.Documents.PaperClause.Changes.Admit
    end

    update :measure_impact do
      description """
      Measure what admitting this draft would change in the tenant's issued
      documents, and store the report on it (`impact_report`). Admission rests
      on it.
      """

      accept []
      require_atomic? false

      validate attribute_equals(:status, :draft),
        message: "only a draft clause is a candidate to measure"

      change AshEnterprise.Documents.Paper.Changes.MeasureImpact
    end

    action :impact_changes, {:array, :map} do
      description """
      The issued documents each measured draft would change: one row per changed
      block with its before and after text, and one per document that failed or
      could not be reproduced. Reads stored reports only.
      """

      run {AshEnterprise.Documents.Paper.Actions.ImpactChanges, read_action: :read}
    end

    update :retire do
      description "Retire an admitted version: it stays readable, bindings go stale."
      accept []
      require_atomic? false

      change transition_state(:retired)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
    end

    attribute :locale, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:en, :fr]
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :runs, {:array, :map} do
      allow_nil? false
      default []
      public? true

      description """
      The wording: `%{"kind" => "text" | "hole", "value" => string}` per run.
      A `"hole"` value names a payload field the render fills.
      """
    end

    attribute :content_hash, :string do
      allow_nil? false
      public? true
      writable? false

      description "`AshPaper.Clause.hash/1` of `runs`; computed, never accepted."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :admitted, :retired]
    end

    attribute :admitted_by_id, :uuid do
      public? true
      writable? false
      description "Who admitted the clause; null when a system actor did."
    end

    attribute :impact_report, :map do
      public? true
      writable? false
      sensitive? true

      description """
      What admitting this draft would change in issued documents, as
      `AshEnterprise.Documents.Paper.Impact.stored/1` keeps it: counts per
      outcome and one case per run, each run's text sealed under its own
      erasure scope. Written by `measure_impact` only.
      """
    end
  end

  calculations do
    calculate :impact_summary,
              :string,
              AshEnterprise.Documents.Paper.Calculations.ImpactSummary do
      public? true
      description "Where the impact report stands: not measured, stale, errored, or its counts."
    end
  end

  @doc """
  The kernel's `%AshPaper.Clause{}` for this row: what
  `AshPaper.Binding.selection/4` pins and `AshPaper.Clause.resolve/3` fills.
  """
  @spec to_kernel(t()) :: AshPaper.Clause.t()
  def to_kernel(%__MODULE__{} = clause), do: AshPaper.Clause.from_stored!(clause)

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    keep(:impact_report,
      because:
        "counts, run ids and outcomes in the clear; every document's text and failure detail is ciphertext sealed under that run's erasure-scope key, which a copy replaces (Erasure.Key.wrapped_key), so it cannot be opened there"
    )
  end
end
