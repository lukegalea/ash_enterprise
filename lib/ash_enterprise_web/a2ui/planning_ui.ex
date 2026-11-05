defmodule AshEnterpriseWeb.A2ui.PlanningUI do
  @moduledoc """
  Planning review (ADR 0061): the candidate plans a solve run proposed, newest
  first, each with its three kept-apart axes — check outcome, freshness and
  disposition — and the person's decision: Approve, Reject, Apply.

  Read-only over structural fields. The sealed `assignments` are never listed;
  the unresolved obligations are ids and reason codes only. A candidate's
  detail names its run, and the run's preparation and solve axes, optimality,
  world and `complete?` read from the run's own detail context.

  Every button runs the candidate's `human_only` update (`:approve`,
  `:reject`, `:apply`) as the clicking person, under their own grants: neither
  the engine nor the system-actor bypass reaches them, and the resource's
  guards refuse `approve`/`apply` unless the check is `:correct` and the
  candidate `:current`. `:apply` records the decision; the version recheck
  and the writes to operational resources happen in the host transaction
  around it. Reads are the self-service reads, bounded to the signed-in
  person's own runs and candidates in their tenant.

  Served at `/app/planning`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Planning.Candidate
    surface_id "planning"
    title "Planning review"
    record_label "candidate plan"
    spec_version "1.0"

    context :candidate do
      resource AshEnterprise.Planning.Candidate
      picker false
    end

    context :run do
      resource AshEnterprise.Planning.Run
      picker false
    end

    query :candidates do
      sortable [:created_on, :index]
      filters [:disposition, :check_status, :freshness, :run_id]
      default_sort created_on: :desc
      page_size 25
      max_page_size 100
    end

    query :runs do
      sortable [:created_on]
      filters [:solve_status, :preparation_status, :world, :optimality]
      default_sort created_on: :desc
      page_size 25
      max_page_size 100
    end

    component :table do
      fields [:index, :check_status, :freshness, :disposition, :run_id, :created_on]
      read_action :read
      query :candidates
      row_actions [:approve, :reject, :apply]
      select_context :candidate
    end

    component :table, :runs do
      fields [
        :preparation_status,
        :solve_status,
        :optimality,
        :complete?,
        :world,
        :outcome_reason,
        :created_on
      ]

      read_action :read
      query :runs
      resource AshEnterprise.Planning.Run
      select_context :run
    end

    component :detail, :candidate_detail do
      context :candidate

      fields [
        :index,
        :run_id,
        :check_status,
        :freshness,
        :disposition,
        :unresolved_obligations,
        :applied_by_actor_id,
        :check_results
      ]
    end

    component :detail, :run_detail do
      context :run

      fields [
        :preparation_status,
        :solve_status,
        :optimality,
        :complete?,
        :world,
        :scenario_ref,
        :outcome_reason,
        :snapshot_digest,
        :knowledge_cutoff,
        :unresolved_inputs
      ]
    end

    action :approve do
      label "Approve"
      visible_when disposition: :proposed, check_status: :correct, freshness: :current
      refreshes [:candidates]
    end

    action :reject do
      label "Reject"
      visible_when disposition: [:proposed, :approved]
      refreshes [:candidates]
    end

    action :apply do
      label "Apply"
      visible_when disposition: :approved, check_status: :correct, freshness: :current
      refreshes [:candidates]
    end

    field :index do
      label "Candidate"
    end

    field :check_status do
      label "Check"
    end

    field :freshness do
      label "Freshness"
    end

    field :disposition do
      label "Decision"
    end

    field :run_id do
      label "Run"
    end

    field :created_on do
      label "Proposed"
    end

    field :unresolved_obligations do
      label "Unresolved"
    end

    field :applied_by_actor_id do
      label "Applied by"
      link {:users, :applied_by_actor_id}
    end

    field :check_results do
      label "Check outcomes"
    end

    field :preparation_status do
      label "Preparation"
    end

    field :solve_status do
      label "Solve"
    end

    field :optimality do
      label "Optimality"
    end

    field :complete? do
      label "Complete"
    end

    field :world do
      label "World"
    end

    field :scenario_ref do
      label "Scenario"
    end

    field :outcome_reason do
      label "Outcome"
    end

    field :snapshot_digest do
      label "Snapshot digest"
    end

    field :knowledge_cutoff do
      label "Knowledge cutoff"
    end

    field :unresolved_inputs do
      label "Unresolved inputs"
    end
  end
end
