defmodule AshEnterprise.Execution do
  @moduledoc """
  Governed execution (ADR 0055): every consequential act this application runs on
  someone's behalf is one `AshEnterprise.Execution.Invocation` row, with a stable key, a
  keyed digest of its arguments, a lease that fences stale workers and a typed outcome.

  The entry point is `invoke/4`:

      AshEnterprise.Execution.invoke(
        "AshEnterprise.Security.UserRole.assign",
        %{"user_id" => user_id, "role_id" => role_id},
        %{key: "access-review:\#{review_id}"},
        actor: actor,
        tenant: tenant
      )

  It returns the invocation row, the same row again for the same key and request, or an
  `AshAgent.Invocation.IdempotencyConflict` for the same key with a different request.
  A ready row runs on the `:execute` trigger, as the requesting person, rebuilt from
  their grants when it is claimed.

  An agent's definition is an `AshEnterprise.Execution.AgentVersion`: registered from
  code, published under four eyes through `request_agent_publish/3`, pinned by the runs
  that use it. `start_agent_run/4` starts a run of an agent's latest published version
  (`AshEnterprise.Execution.Run`): one model call per job, every tool call that is not an
  in-loop read an invocation, the journal its `AshEnterprise.Execution.Step` rows.

  A release (`AshEnterprise.Execution.ReleaseManifest`) is an immutable set of agents,
  tools, decisions and the rest that were tested together: resolved from what is published,
  gated on suite runs of exactly that set, approved under four eyes and promoted, with
  rollback and an in-toto export.

  `trace/2` follows one piece of work through every record it left, in order and as the
  caller may read them (`AshEnterprise.Execution.Entry`, over the sources registered in
  `AshEnterprise.ExecutionSources`).

  The resources come from the `ash_agent` package's fragments instantiated on the
  platform base (ADR 0056); this domain names them and their code interfaces.
  """

  use Ash.Domain

  resources do
    resource AshEnterprise.Execution.Invocation do
      define :invoke, action: :invoke, args: [:target, :args]
      define :request_invocation, action: :request
      define :confirm_invocation, action: :confirm, args: [:target, :args, :key]
      define :get_invocation, action: :read, get_by: [:id]
      define :list_invocations, action: :read
      define :claim_invocation, action: :claim
      define :apply_invocation_decision, action: :apply_decision
      define :request_invocation_cancel, action: :request_cancel
      define :execute_invocation, action: :execute, args: [:primary_key]
      define :reconcile_invocation, action: :reconcile, args: [:primary_key]
      define :complete_invocation_externally, action: :complete_external
      define :request_invocation_resolution, action: :request_resolution
      define :apply_invocation_resolution, action: :apply_resolution
      define :retry_invocation, action: :retry
    end

    resource AshEnterprise.Execution.AgentVersion do
      define :register_agent_from_code, action: :register_from_code, args: [:agent]
      define :create_agent_draft, action: :create_draft
      define :revise_agent_draft, action: :revise_draft
      define :fork_agent_for_tenant, action: :fork_for_tenant, args: [:key]
      define :request_agent_publish, action: :request_publish, args: [:record_id]
      define :enable_agent_from_code, action: :enable_from_code, args: [:agent]
      define :retire_agent_version, action: :retire
      define :get_agent_version, action: :read, get_by: [:id]
      define :latest_published_agent_version, action: :latest_published, args: [:key]
      define :list_agent_versions, action: :read
    end

    resource AshEnterprise.Execution.ReleaseManifest do
      define :create_release_draft, action: :draft
      define :resolve_release_manifest, action: :resolve
      define :check_release_gate, action: :check_gate
      define :request_release, action: :request_release, args: [:record_id]
      define :promote_release, action: :promote
      define :supersede_release_manifest, action: :supersede
      define :rollback_release, action: :rollback
      define :export_release_attestation, action: :export_attestation, args: [:record_id]
      define :get_release_manifest, action: :read, get_by: [:id]
      define :active_release_manifests, action: :active
      define :list_release_manifests, action: :read
    end

    resource AshEnterprise.Execution.Run do
      define :start_agent_run, action: :start, args: [:agent, :input]
      define :get_agent_run, action: :read, get_by: [:id]
      define :get_agent_run_by_key, action: :read, get_by: [:run_key]
      define :list_agent_runs, action: :read
      define :request_agent_run_cancel, action: :request_cancel
      define :step_agent_run, action: :step, args: [:primary_key]
      define :recover_agent_run, action: :recover
      define :reserve_agent_run_budget, action: :reserve
      define :settle_agent_run_budget, action: :settle
      define :extend_agent_run_budget, action: :extend, args: [:tokens]
    end

    resource AshEnterprise.Execution.Step do
      define :list_agent_steps, action: :read
    end

    resource AshEnterprise.Execution.RunFinished do
      define :emit_run_finished, action: :emit
      define :list_run_finished, action: :read
    end

    resource AshEnterprise.Execution.Entry do
      define :trace, action: :trace
    end

    resource AshEnterprise.Execution.HumanInput
    resource AshEnterprise.Execution.StartProcess
  end
end
