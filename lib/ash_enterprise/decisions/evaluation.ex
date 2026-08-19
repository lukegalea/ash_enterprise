defmodule AshEnterprise.Decisions.Evaluation do
  @moduledoc """
  What a decision was asked, and what it answered.

  Append-only evidence: the decision, the definition version that decided, the inputs it saw,
  the outputs it produced, and how long it took. This is the row that answers *why did this
  case go that way* — the question a rules engine is bought for and the one a hand-written
  `case` in an action cannot answer at all.

  Not audited by `AshEvents`, because it is already the record of an evaluation rather than a
  change to one. Auditing it would be auditing a log, and the rule that keeps the trails honest
  is that no two of them describe the same fact.
  """

  use AshDecisions.Resources.Evaluation,
    domain: AshEnterprise.Decisions,
    repo: AshEnterprise.Repo,
    table: "dmn_evaluations",
    definition: AshEnterprise.Decisions.Definition,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      lifecycle?: false,
      audit?: false,
      archival?: false
    ]
end
