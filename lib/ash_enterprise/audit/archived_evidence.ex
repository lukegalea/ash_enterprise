defmodule AshEnterprise.Audit.ArchivedEvidence do
  @moduledoc """
  Evidence artifacts that have left the hot table (`AshCompliance.Resources.EvidenceArtifact`):
  the archive store for evidence, beside `AshEnterprise.Audit.ArchivedEvent` for the log.

  `AshCompliance.Ownership.Retention` (run by `AshEnterprise.Audit.Retention`) moves an
  artifact here once it is older than the hot window (ninety days) **and** a newer artifact
  exists for the same organization, control and collector. The table, its columns, its
  index, its guard trigger and its `:read` and `:for_control` actions are `ash_compliance`'s
  evidence archive (`{:evidence_archive, ...}`): the hot table's columns plus `archived_at`,
  so an archived artifact still hashes to its `hash`. This module adds who may read it.

  Every read of evidence for a period takes the hot table and this archive together
  (`AshCompliance.Ownership.Evidence.for_control/3`, named by `config :ash_compliance,
  evidence_archive: ...`), so the freshness sweep and the audit package find the same
  artifacts after a move as before it.

  Not a platform resource, for `AshEnterprise.Audit.ArchivedEvent`'s reason: it is a moved
  copy of rows that were written once, and has no create, update or destroy action. The
  trigger refuses every `UPDATE`, and every `DELETE` of an artifact collected less than
  four hundred days ago.
  """

  use Ash.Resource,
    domain: AshEnterprise.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # The table `evidence_artifact_archive`, its control index, its guard statements (under
  # the guard function's name the table has always had), its attributes and its actions.
  use AshCompliance.Resources,
      {:evidence_archive,
       table: "evidence_artifact_archive",
       repo: AshEnterprise.Repo,
       guard_function: "ash_enterprise_evidence_archive_guard"}

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
