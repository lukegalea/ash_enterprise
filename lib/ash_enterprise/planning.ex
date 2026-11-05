defmodule AshEnterprise.Planning do
  @moduledoc """
  Planning (ADR 0062): a constraint-solving proposal kernel over document-based MiniZinc
  models. Planning proposes; declarations and people commit.

    * `AshEnterprise.Planning.ModelVersion`: an immutable, content-hashed model, checker and
      validator triple, `draft → published → retired`.
    * `AshEnterprise.Planning.Binding`: the temporal binding of `(model_key, purpose)` to the
      definitions a tenant's plans are made with.
    * `AshEnterprise.Planning.Run`: one request to solve, with the preparation and solve
      axes kept apart, a lease, and sealed problem and result payloads.
    * `AshEnterprise.Planning.Candidate`: a proposed plan. Never an operational fact: a
      person approves and applies it, through existing Ash actions, after a freshness
      recheck.
    * `AshEnterprise.Planning.CheckResult`: create-only outcomes of the MiniZinc checker and
      the independent Elixir validator.

  The resources instantiate the `AshEnterprise.Planning.Fragment.*` fragments on the platform
  base: the fragments are the contract and move into the `ash_planning` package; this
  domain owns the host side (tenancy, authority, audit, sealing, policies).

  Authorization decides who may request, inspect, approve or apply a plan. It is never a
  solver constraint.
  """

  use Ash.Domain, otp_app: :ash_enterprise

  resources do
    resource AshEnterprise.Planning.ModelVersion do
      define :draft_model_version, action: :draft
      define :revise_model_version, action: :revise
      define :publish_model_version, action: :publish
      define :retire_model_version, action: :retire
      define :get_model_version, action: :read, get_by: [:id]
      define :list_model_versions, action: :read
    end

    resource AshEnterprise.Planning.Binding do
      define :bind_planning_model, action: :bind
      define :rebind_planning_model, action: :rebind
      define :unbind_planning_model, action: :unbind
      define :get_planning_binding, action: :read, get_by: [:id]
      define :get_planning_binding_by_selector, action: :read, get_by: [:selector]
      define :list_planning_bindings, action: :read
    end

    resource AshEnterprise.Planning.Run do
      define :request_planning_run, action: :request
      define :cancel_planning_run, action: :cancel, args: [:run_id]
      define :request_planning_run_cancel, action: :request_cancel
      define :prepare_planning_run, action: :prepare
      define :start_planning_run, action: :start
      define :renew_planning_run_lease, action: :renew_lease
      define :record_planning_result, action: :record_result
      define :get_planning_run, action: :read, get_by: [:id]
      define :list_planning_runs, action: :read
      define :my_planning_runs, action: :mine
    end

    resource AshEnterprise.Planning.Candidate do
      define :propose_planning_candidate, action: :propose
      define :record_planning_check, action: :record_check
      define :mark_planning_candidate_stale, action: :mark_stale
      define :approve_planning_candidate, action: :approve
      define :reject_planning_candidate, action: :reject
      define :apply_planning_candidate, action: :apply
      define :supersede_planning_candidate, action: :supersede
      define :get_planning_candidate, action: :read, get_by: [:id]
      define :list_planning_candidates, action: :read
    end

    resource AshEnterprise.Planning.CheckResult do
      define :record_planning_check_result, action: :record
      define :list_planning_check_results, action: :read
    end
  end
end
