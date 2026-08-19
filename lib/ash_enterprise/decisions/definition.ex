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
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      # `draft -> published -> retired` is the definition's own state machine.
      lifecycle?: false,
      audit?: true,
      archival?: false
    ]
end
