defmodule AshEnterprise.Bpmn do
  @moduledoc """
  Business processes: the definitions people draw, and the instances the engine runs.

  Six resources supplied by `ash_bpmn` and instantiated here, so that the tables belong to
  this application rather than to a library — the pattern `ash_events` uses for its event log,
  and the reason a process instance can be an ordinary owned, tenant-scoped, audited record
  instead of a row in a workflow engine's private schema. That is the load-bearing claim of
  [ADR 0009](../../docs/adr/0009-strangler-and-bpmn-are-first-party.md): one authorization
  model underneath all of it, so *who may approve* is a role grant evaluated by the same union
  of grants as *who may read*.

  ## What is audited, and what deliberately is not

  Not every one of the six carries the audit hook, and the choice is about signal rather than
  cost. A `Definition` being published and a `HumanTask` being decided are governance events —
  someone changed how the business works, someone approved something — and they belong in the
  trail an auditor reads. A `Token` moving between nodes is the engine's own bookkeeping;
  auditing it would add thousands of rows saying nothing a `ProcessEvent` does not already say
  better, and `docs/manifesto/02` is explicit that two logs which overlap will disagree.

  `ProcessEvent` is itself append-only and is the engine's log, so auditing it would be
  auditing an audit.

  ## Not exposed over the public APIs

  No `api_type`. A process definition is operational configuration and a token is engine
  state; neither is a thing an API consumer should be reading or writing, and the surfaces
  that *should* exist — the task list, the designer, the viewer — are LiveViews with the
  actor's own grants behind them.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Bpmn.Definition
    resource AshEnterprise.Bpmn.Instance
    resource AshEnterprise.Bpmn.Token
    resource AshEnterprise.Bpmn.HumanTask
    resource AshEnterprise.Bpmn.TaskCandidate
    resource AshEnterprise.Bpmn.ProcessEvent
  end
end
