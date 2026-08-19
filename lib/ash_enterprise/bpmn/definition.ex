defmodule AshEnterprise.Bpmn.Definition do
  @moduledoc """
  A published BPMN document, compiled into an immutable versioned graph.

  Audited, because publishing one is a governance act: it changes how a business process
  behaves for everyone it applies to, without a deploy, and "who changed the approval chain
  and when" is a question an auditor asks first.
  """

  use AshBpmn.Resources.Definition,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_definitions",
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      # A definition has its own `draft -> published -> retired` lifecycle, and
      # `ash_state_machine` allows exactly one state attribute per resource. The platform's
      # `lifecycle_status` would be a second one.
      lifecycle?: false,
      audit?: true,
      # Immutable once published, so there is nothing for soft delete to mean: `retire` is the
      # deliberate end of a definition's life and it keeps the row, because instances pinned
      # to it are still running.
      archival?: false
    ]
end
