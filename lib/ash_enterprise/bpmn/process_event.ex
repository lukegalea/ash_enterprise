defmodule AshEnterprise.Bpmn.ProcessEvent do
  @moduledoc """
  Process-level facts the event log structurally cannot express.

  A token created or consumed, a gateway branch taken and the condition that chose it, a timer
  fired or cancelled, a decision evaluated, a task assigned or escalated. None of those is a
  row change, so none of them appears in `AshEnterprise.Audit.EventLog` — and the rule that
  keeps the two honest is that this log **never duplicates a mutation**. If it changed a row,
  it is in the event log; if it explains *why* a row changed, it is here. Correlated by the
  correlation id both already carry.

  Not audited, for the obvious reason: this is a log.
  """

  use AshBpmn.Resources.ProcessEvent,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_process_events",
    instance: AshEnterprise.Bpmn.Instance,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      lifecycle?: false,
      audit?: false,
      archival?: false
    ]
end
