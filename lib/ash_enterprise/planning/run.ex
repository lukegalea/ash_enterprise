defmodule AshEnterprise.Planning.Run do
  @moduledoc """
  One planning run (ADR 0062): `AshEnterprise.Planning.Fragment.Run` on the platform base, in
  table `planning_runs`. A run is rows and a lease, not a process: the solver session is
  supervised separately (`AshEnterprise.Planning.SolverSession`) and the row decides
  recovery.

  The fragment supplies the contract: the pinned model version, binding and snapshot digest,
  the preparation and solve axes kept apart, `complete?`, `optimality`, the lease, and
  the actions that move them. There is no objective, bound or gap column: they are decimals
  and live inside the sealed `result_payload`.

  ## Who may do what (ADR 0059, ADR 0052)

    * `request` and `cancel` are **self-service**: any active member may ask for a plan for
      themselves and cancel their own run. `cancel` is a generic action over the requester's
      own rows (`AshEnterprise.Planning.Actions.CancelOwnRun`); an operator cancels through
      `request_cancel` under their grants. `mine` and `read` are self-service reads bounded
      to the actor's own rows.
    * `prepare`, `start`, `renew_lease` and `record_result` are **machinery-only**: only the
      `oban` system actor reaches them, and no grant row does. A person never writes a
      run's axes, lease or result.
    * Everything else goes through the grant union.

  ## Ownership and sealing

  User-owned: `request` stamps the requester as `owner_id` and opens (or finds) their own
  erasure scope. `problem_payload` and `result_payload` are sealed under that scope
  (`AshEnterprise.Erasure.Changes.SealUnderScope`), so the audit event of every write carries
  ciphertext only, and shredding the scope makes both unreadable while the row, its axes and
  its audit chain stay. A run is never destroyed (`archival?: false`, no destroy action).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Planning,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:request, :cancel, :mine, :read],
    machinery_only: [:prepare, :start, :renew_lease, :record_result],
    extra_extensions: [AshCloak],
    fragments: [AshEnterprise.Planning.Fragment.Run]

  alias AshEnterprise.Planning.Changes

  postgres do
    table "planning_runs"
    repo AshEnterprise.Repo

    references do
      reference :model_version, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end

    # The lease sweep's query, across tenants, every minute.
    custom_indexes do
      index [:lease_expires_at], all_tenants?: true, where: "solve_status IS NULL"
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:problem_payload, :result_payload]
    encrypt_nil?(false)
  end

  changes do
    change {Changes.PinModel, stage: :request}, on: [:create]
    change {Changes.PinModel, stage: :prepare}, on: [:update], where: action_is(:prepare)
    change {Changes.ScopeAndOwner, from: :requester}, on: [:create]

    change {AshEnterprise.Erasure.Changes.SealUnderScope,
            fields: [:problem_payload, :result_payload]},
           on: [:create, :update]
  end

  actions do
    read :mine do
      description "The actor's own runs, newest first."
      filter expr(owner_id == ^actor(:id) and owner_type == :user)
      prepare build(sort: [inserted_at: :desc])
    end

    action :cancel, :struct do
      description "Cancel one of the actor's own runs."
      constraints instance_of: __MODULE__
      argument :run_id, :uuid, allow_nil?: false
      run AshEnterprise.Planning.Actions.CancelOwnRun
    end
  end

  relationships do
    belongs_to :model_version, AshEnterprise.Planning.ModelVersion do
      public? true
      define_attribute? false
      description "The pinned model version."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      description "The scope `problem_payload` and `result_payload` are sealed under."
    end

    has_many :candidates, AshEnterprise.Planning.Candidate do
      public? true
      sort index: :asc
      description "What the run proposed."
    end
  end

  @doc """
  The binding this run resolves to: the version valid **as of the run's `knowledge_cutoff`**,
  never the live one (ADR 0062). `{:error, :not_prepared}` for a run with no cutoff yet.

  There is deliberately no `binding` relationship: a loaded relationship reads as of the
  query's instant, which is now, and a replay must not see a binding changed after its
  cutoff. The snapshot builder copies the resolved `selection` into the snapshot.
  """
  @spec resolve_binding(%__MODULE__{}) :: {:ok, struct()} | {:error, term()}
  def resolve_binding(%__MODULE__{knowledge_cutoff: nil}), do: {:error, :not_prepared}

  def resolve_binding(%__MODULE__{} = run) do
    Ash.get(AshEnterprise.Planning.Binding, run.binding_id,
      tenant: run.organization_id,
      as_of: run.knowledge_cutoff,
      authorize?: false
    )
  end
end
