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
  """

  use AshBpmn.Resources.Dispatch,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_dispatches",
    subscription: AshEnterprise.Bpmn.Subscription,
    token: AshEnterprise.Bpmn.Token,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      lifecycle?: false,
      # Refused, not merely declined: see the moduledoc.
      audit?: false,
      archival?: false
    ]
end
