defmodule AshEnterprise.Decisions.Definition do
  @moduledoc """
  A published DMN document, compiled into an immutable versioned snapshot.

  Audited for the same reason a process definition is: publishing one changes how the business
  decides, for everyone it applies to, without a deploy.
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

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    keep(:xml,
      because:
        "a tenant's decision tables, not personal data; sensitive? keeps them out of log lines, and the stored bytes are what content_hash names"
    )
  end
end
