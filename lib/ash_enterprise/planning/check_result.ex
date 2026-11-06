defmodule AshEnterprise.Planning.CheckResult do
  @moduledoc """
  One check of one candidate (ADR 0062): `AshPlanning.Fragment.CheckResult` on the
  platform base, in table `planning_check_results`.

  Create-only: there is no update and no destroy, and a re-check is a new row. The MiniZinc
  solution checker and the independent Elixir validator are recorded separately, as status
  and reason codes in clear columns; the violations themselves are in `violation_details`,
  sealed under the candidate's erasure scope.

  ## Who may do what (ADR 0059)

  `record` is **machinery-only**: the check pipeline writes it as the `oban` system actor,
  and no grant row reaches it. `read` is a self-service read bounded to the actor's own
  rows; everything else goes through the grant union.

  ## Ownership and sealing

  User-owned, and `record` takes its owner and erasure scope from its candidate
  (`AshEnterprise.Planning.Changes.ScopeAndOwner`), never from input. Not a lifecycle
  resource and never soft-deleted.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Planning,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    self_service: [:read],
    machinery_only: [:record],
    extra_extensions: [AshCloak],
    fragments: [AshPlanning.Fragment.CheckResult]

  alias AshEnterprise.Planning.Changes

  postgres do
    table "planning_check_results"
    repo AshEnterprise.Repo

    references do
      reference :candidate, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes [:violation_details]
    encrypt_nil?(false)
  end

  changes do
    change {Changes.ScopeAndOwner, from: :candidate}, on: [:create]

    change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:violation_details]},
      on: [:create]
  end

  relationships do
    belongs_to :candidate, AshEnterprise.Planning.Candidate do
      public? true
      define_attribute? false
      description "The candidate that was checked."
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      public? true
      description "The candidate's scope, which `violation_details` is sealed under."
    end
  end
end
