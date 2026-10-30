defmodule Battery.Execution.Invocation do
  @moduledoc """
  The battery's governed invocations: the `AshAgent.Invocation` fragment on a plain
  resource, with the approval seam to ash_bpmn wired the way a host wires it.

    * `request` opens a standalone approval task for a row that awaits one
      (`Battery.Execution.RequestApproval`, delegating to
      `AshBpmn.Changes.RequireApproval`);
    * `apply_decision` reads the decided task (`Battery.Execution.ReadApproval`). The
      fragment then applies the outcome only while the approval still binds the
      request.

  No triggers: the battery drives `apply_decision` and `execute` itself.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Invocation]

  postgres do
    table "battery_invocations"
    repo Battery.Repo
  end

  invocation do
    execution_identity(Battery.Execution.Identity)
    digest_key(Battery.Execution.DigestKey)
  end

  changes do
    change set_attribute(:owner_id, actor(:id)), on: [:create]
    change Battery.Execution.RequestApproval, where: [action_is(:request)]
    change Battery.Execution.ReadApproval, where: [action_is(:apply_decision)]
  end

  attributes do
    attribute :owner_id, :uuid, public?: true
  end
end
