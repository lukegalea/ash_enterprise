defmodule AshEnterprise.Bpmn.Dispatch do
  @moduledoc """
  What the trigger sweep did with one audit event, for one subscription —
  `AshBpmn.Resources.Dispatch` instantiated on the platform base.

  Append-only (the macro generates create and read and nothing else), one row
  per `(subscription_id, event_id)` written **in the same transaction as the
  instance start**: the identity is what makes duplicate starts *provably*
  impossible under a partial failure, and the row is what answers **"why did
  this process start?"** — the question anyone asks first when a process
  appears that nobody remembers requesting.

  ## Not audited, by refusal

  Setting `audit?: true` on a dispatch would be a cycle with extra steps: a
  dispatch is already the record of an event, and two logs describing the same
  fact will eventually disagree. The same reasoning removes it from the soft
  delete and lifecycle machinery — there is no draft dispatch and nothing for
  archival to mean.

  ## The depth column, and the cycle it bounds

  Some BPMN and decision resources carry the audit hook, so a process started
  by a subscription writes audit events, and those are subscription inputs.
  Matching an `ash_bpmn` or `ash_decisions` resource is refused at publish
  time, which closes the direct path; `depth` bounds the indirect one through
  `AshBpmn.Resources.Signal`, so a cycle is *bounded* rather than merely
  improbable.

  ## Written by the engine alone

  `create` is `engine_only` (ADR 0069): the trigger sweep writes it, as an engine-marked
  call, and no role grant and no system actor reaches it. The row is what
  `AshEnterprise.Process.RecipeAuthority` decides a standing grant from, so a dispatch a
  person could write naming their own instance would run that instance's steps as a
  publisher's recipe runner.

  ## Telemetry

  The package's `create` reports how long an event waited for the process it started
  (`[:ash_bpmn, :triggers, :dispatch, :start]`, `AshBpmn.Triggers.Telemetry`); the metric
  is declared in `AshEnterpriseWeb.Telemetry.bpmn_metrics/0`.

  ## The cause, which is never authority

  `caused_by_id` names the person whose write caused the event, copied from the started
  instance (`AshEnterprise.Bpmn.Dispatch.RecordCause`). It answers "whose act set this
  off", and nothing reads it to decide what the process may do: that comes from the
  subscription's `authority` (ADR 0069).
  """

  use AshBpmn.Resources.Dispatch,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_dispatches",
    # Without its own engine bypass: the platform's, narrowed by `EngineReach`, is the
    # engines' only one, so nothing they mark reaches a human_only action (ADR 0059).
    policies?: false,
    subscription: AshEnterprise.Bpmn.Subscription,
    token: AshEnterprise.Bpmn.Token,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      lifecycle?: false,
      # Refused, not merely declined: see the moduledoc.
      audit?: false,
      archival?: false,
      # The sweep's own record, and the row a standing grant is decided from: only the
      # engine writes one. See "Written by the engine alone" in the moduledoc.
      engine_only: [:create]
    ]

  attributes do
    attribute :caused_by_id, :uuid do
      public? true

      description "The person whose write caused the event, when one did. Provenance, " <>
                    "never authority."
    end
  end

  changes do
    change {AshEnterprise.Bpmn.Dispatch.RecordCause, []}, on: [:create]
  end
end
