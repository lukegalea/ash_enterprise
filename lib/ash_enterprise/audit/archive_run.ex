defmodule AshEnterprise.Audit.ArchiveRun do
  @moduledoc """
  One retention step, recorded: an archive of a run of rows out of a hot table, or a purge of
  a run of rows out of an archive (`AshEvents.Chain.Retention` for the audit log,
  `AshEnterprise.Audit.Retention` for evidence).

  A row says what moved (`store`, `kind`, the chain and sequence range for the audit log),
  how many rows, the SHA-256 `digest` of their hashes in order, and whether the copy
  verified. A failed verification is recorded too, with its `reason`: nothing was deleted,
  and the row is the evidence that the step was tried and refused.

  A purge of the audit archive also records the `tail_hash` of the last purged event. The
  chain verifier (`AshEvents.Chain.verify/2`) starts the chain from that anchor, so the
  rows that remain still verify after the oldest have gone.

  The table, its attributes, its anchor index and the `:read` and `:record` actions are
  `ash_events_chain`'s run ledger (`{:archive_run, ...}`); `store` is the hot table a run
  moved rows out of, `audit_events` or `evidence_artifacts`.

  Append-only and machinery-only: `record` is run by the `oban` system actor
  (`AshEnterprise.Security.ActionReach`), there is no update or destroy, and reading follows
  the grant union. Audited like any platform write, so the log holds its own retention
  history.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Audit,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:record]

  use AshEvents.Chain.Resources,
      {:archive_run,
       log: AshEnterprise.Audit.EventLog,
       table: "audit_archive_runs",
       repo: AshEnterprise.Repo,
       chain_attribute: :chain_organization_id}
end
