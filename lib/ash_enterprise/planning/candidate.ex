defmodule AshEnterprise.Planning.Candidate do
  @moduledoc """
  One candidate plan a run proposed (ADR 0062): `AshPlanning.Fragment.Candidate` on
  the platform base, in table `planning_candidates`. A candidate is a proposal, never an
  operational fact: no operational resource reads this table, so an unapplied candidate is
  inert.

  The fragment supplies the contract: the run and index, the sealed assignments, the
  unresolved obligations (ids and reason codes only), and the check, freshness and
  disposition axes kept apart, with the guards on which moves are allowed from which state.

  ## Who may do what (ADR 0059)

    * `propose`, `record_check`, `mark_stale` and `supersede` are **machinery-only**: the
      solve job and the check pipeline write them, as the `oban` system actor, and no grant
      row reaches them.
    * `approve`, `reject` and `apply` are **human-only**: neither engine bypass nor the
      system-actor bypass reaches them, so only the calling person's own grants authorize
      one. A person's decision is never made by machinery, and an agent reaches `apply` only
      through a governed invocation a person approves.
    * `read` is a self-service read bounded to the actor's own candidates.

  ## Ownership and sealing

  User-owned, and `propose` takes its owner and erasure scope from its run
  (`AshEnterprise.Planning.Changes.ScopeAndOwner`), never from input: the person who asked for
  the plan reads, approves and applies its candidates under the same owner grants. The
  assignments are sealed under the run's scope; once it is shredded they read as erased while
  the row's axes and its audit chain stay. Rows are never destroyed.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Planning,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:read],
    machinery_only: [:propose, :record_check, :mark_stale, :supersede],
    human_only: [:approve, :reject, :apply],
    extra_extensions: [AshCloak],
    fragments: [AshPlanning.Fragment.Candidate]

  alias AshEnterprise.Planning.Changes

  postgres do
    table "planning_candidates"
    repo AshEnterprise.Repo

    references do
      reference :run, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:assignments]
    encrypt_nil?(false)
  end

  changes do
    change {Changes.ScopeAndOwner, from: :run}, on: [:create]

    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:assignments]},
      on: [:create, :update]

    change AshEnterprise.Planning.Changes.ApplyCandidate,
      on: [:update],
      where: action_is(:apply)
  end

  relationships do
    belongs_to :run, AshEnterprise.Planning.Run do
      public? true
      define_attribute? false
      description "The run that proposed the candidate."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      description "The run's scope, which `assignments` is sealed under."
    end

    has_many :check_results, AshEnterprise.Planning.CheckResult do
      public? true
      description "Every check of the candidate, oldest first."
      sort inserted_at: :asc
    end
  end
end
