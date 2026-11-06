defmodule AshEnterprise.Execution.Intervention do
  @moduledoc """
  A person's act on one invocation from the recovery surface (`AshEnterpriseWeb.RecoveryLive`),
  with who did it and why: one row per act, written in the same transaction as the act,
  so an act that is refused leaves no row and a row always names an act that happened.

  | Action | The act | Run as the person, through |
  |---|---|---|
  | `rerun` | a new request for the same target and arguments, with a new key, linked to the row | `Invocation.rerun` (self-service) |
  | `cancel` | stops a request that has not run; marks one that is running | `Invocation.request_cancel` (the grant union) |
  | `resolve` | settles an unknown outcome: it `succeeded`, it `failed`, or it did not and runs again (`retry`) under the same request | `HumanTask.resolve` on the row's resolution task (a candidate's grant) |

  Each is self-service here: the act it wraps is the one the person's authority is
  checked on, as them, and a refusal there refuses the whole act. The reason is
  required. The trace shows each row under its invocation
  (`AshEnterprise.ExecutionSources.Intervention`).

  `simulate` is not an intervention: it writes nothing. It says what a rerun would run
  now (`AshEnterprise.Execution.Actions.SimulateRerun`).

  Which act is offered for which status is `AshEnterprise.Execution.Recovery`'s.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:read, :rerun, :cancel, :resolve, :simulate]

  alias AshEnterprise.Execution.Changes.Intervene

  postgres do
    table "exec_interventions"
    repo AshEnterprise.Repo
  end

  actions do
    defaults [:read]

    create :rerun do
      description "Rerun an invocation as a new request of yours, saying why."
      accept [:invocation_id, :reason]
      change {Intervene, act: :rerun}
    end

    create :cancel do
      description "Cancel an invocation that has not finished, saying why."
      accept [:invocation_id, :reason]
      change {Intervene, act: :cancel}
    end

    create :resolve do
      description "Settle an invocation whose outcome is unknown, saying what happened and why."
      accept [:invocation_id, :reason, :resolution]
      validate present(:resolution)
      change {Intervene, act: :resolve}
    end

    action :simulate, :map do
      description """
      What a rerun of the invocation would run now, checked without running it: nothing
      is created.
      """

      argument :invocation_id, :uuid, allow_nil?: false
      run AshEnterprise.Execution.Actions.SimulateRerun
    end
  end

  changes do
    change set_attribute(:owner_id, actor(:id)), on: [:create]
  end

  attributes do
    uuid_primary_key :id

    attribute :act, :atom do
      allow_nil? false
      public? true
      writable? false
      constraints one_of: [:rerun, :cancel, :resolve]
      description "What the person did."
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints max_length: 2000
      description "Why, in the person's words."
    end

    attribute :resolution, :atom do
      public? true
      constraints one_of: [:succeeded, :failed, :retry]
      description "For `resolve`: what the person said happened."
    end
  end

  relationships do
    belongs_to :invocation, AshEnterprise.Execution.Invocation do
      allow_nil? false
      public? true
      description "The invocation acted on."
    end

    belongs_to :rerun, AshEnterprise.Execution.Invocation do
      public? true
      attribute_writable? false
      description "For `rerun`: the new request."
    end
  end
end
