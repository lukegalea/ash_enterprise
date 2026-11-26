defmodule AshEnterprise.Decisions.Definition do
  @moduledoc """
  A published DMN document, compiled into an immutable versioned snapshot.

  Audited for the same reason a process definition is: publishing one changes how the business
  decides, for everyone it applies to, without a deploy.

  ## What publishing would change

  `impact_report` is the host's one addition to the package's attribute set: what publishing
  a draft would change, measured before anyone publishes it. Only the `paper.clause.*` family
  measures one today (`measure_impact`, `AshEnterprise.Documents.Paper.Impact`): the draft is
  replayed over the key's recorded evaluations and each case mapped back to the document it
  decided, and `AshEnterprise.Documents.Paper.ClauseTableVerifier` refuses the publish unless
  that report was measured for exactly this version's content hash and no document in it
  failed. It is an attribute of the version because it is about the version: `save_xml`
  changes the content hash, and the report then reads as stale.
  """

  use AshDecisions.Resources.Definition,
    domain: AshEnterprise.Decisions,
    repo: AshEnterprise.Repo,
    table: "dmn_definitions",
    # Without its own engine bypass: the platform's, narrowed by `EngineReach`, is the
    # engines' only one, so nothing they mark reaches a human_only action (ADR 0059).
    policies?: false,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      # `draft -> published -> retired` is the definition's own state machine.
      lifecycle?: false,
      audit?: true,
      archival?: false
    ]

  attributes do
    attribute :impact_report, :map do
      public? true
      writable? false

      description """
      What publishing this draft would change, as
      `AshEnterprise.Documents.Paper.Impact.stored/1` keeps it. Written by
      `measure_impact` only.
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

  actions do
    read :paper_clause_tables do
      description "The `paper.clause.*` decision versions: the tables that put wording in documents."
      filter expr(contains(key, "paper.clause."))
      prepare build(sort: [key: :asc, version: :desc])
    end

    update :measure_impact do
      description """
      Measure what publishing this draft `paper.clause.*` table would change in
      the tenant's issued documents, as the acting person, and store the report
      (`impact_report`). The publish rests on it.
      """

      accept []
      require_atomic? false

      validate attribute_equals(:status, :draft),
        message: "only a draft table is a candidate to measure"

      validate match(:key, ~r/\Apaper\.clause\./),
        message: "impact is measured for paper.clause.* tables only"

      change AshEnterprise.Documents.Paper.Changes.MeasureImpact
    end

    action :impact_changes, {:array, :map} do
      description """
      The issued documents each measured draft table would change: one row per
      document that would gain or lose the clause, change its reason, or failed.
      Reads stored reports only.
      """

      run {AshEnterprise.Documents.Paper.Actions.ImpactChanges, read_action: :paper_clause_tables}
    end
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    keep(:xml,
      because:
        "a tenant's decision tables, not personal data; sensitive? keeps them out of log lines, and the stored bytes are what content_hash names"
    )
  end
end
