defmodule AshEnterprise.Execution.Step do
  @moduledoc """
  One message in an agent run's journal (ADR 0056): the `AshAgent.Step` fragment on the
  platform base, in table `exec_agent_steps`. A model turn and each of its tool results
  are separate steps, numbered in order (`seq`), never changed.

  ## What this resource adds

    * **Written only by the run.** `append` is machinery-only, and only
      `AshEnterprise.Execution.Run`'s `record_step` calls it, inside its fenced
      transaction: a step commits with the run transition that records it, or not at
      all. There is no update and no destroy.
    * **Ownership from the run.** `owner_id` is the run's
      (`AshEnterprise.Execution.Changes.FromRun`), so the person who started a run reads
      its steps through the same grants that let them read the run, with no join.
    * **Sealing.** `parts` is sealed under the run's erasure scope (ADR 0024).
    * **Not audited** (`audit?: false`): the journal is the append-only content ledger,
      as `AshEnterprise.AI.ModelCall` is; the run transition that commits with each step
      is audited.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    lineage?: false,
    self_service: [:read],
    machinery_only: [:append],
    extra_extensions: [AshCloak],
    fragments: [AshAgent.Step]

  postgres do
    table "exec_agent_steps"
    repo AshEnterprise.Repo

    references do
      reference :run, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:parts]
    encrypt_nil?(false)
  end

  changes do
    change AshEnterprise.Execution.Changes.FromRun, on: [:create]
    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:parts]}, on: [:create]
  end

  relationships do
    belongs_to :run, AshEnterprise.Execution.Run do
      public? true
      define_attribute? false
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      public? true
      description "The run's erasure scope, which `parts` is sealed under."
    end
  end
end
