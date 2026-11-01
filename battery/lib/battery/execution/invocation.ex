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
    * `dispatch` of an agent's question (`Battery.Execution.HumanInput`) opens the
      question's task for the person the run acts for
      (`Battery.Execution.OpenInputTask`), and `collect_input` completes the row from
      the answered task (`Battery.Execution.CollectInput`).
    * A row of an agent run that finishes wakes the run (`AshAgent.Run.Changes.Wake`),
      which here enqueues nothing: the run resource has no `:step` trigger.

  No triggers: the battery drives `apply_decision`, `execute`, `collect_input` and
  the run's steps itself.
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

  actions do
    action :collect_input, :atom do
      constraints one_of: [:succeeded, :failed, :skipped]
      argument :primary_key, :map, allow_nil?: false
      run Battery.Execution.CollectInput
    end
  end

  changes do
    change set_attribute(:owner_id, actor(:id)), on: [:create]
    change Battery.Execution.RequestApproval, where: [action_is(:request)]
    change Battery.Execution.ReadApproval, where: [action_is(:apply_decision)]
    change Battery.Execution.OpenInputTask, where: [action_is(:dispatch)]
    change {AshAgent.Run.Changes.Wake, run: Battery.Execution.Run}, on: [:update]
  end

  attributes do
    attribute :owner_id, :uuid, public?: true
  end
end
