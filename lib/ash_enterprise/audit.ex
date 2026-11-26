defmodule AshEnterprise.Audit do
  @moduledoc """
  The audit domain: one central, append-only event log covering every platform
  resource.

  See ADR 0002 for why this is a single log rather than per-resource version
  tables, and `docs/manifesto/04-batteries-are-inherited.md` for how resources
  are wired to it by inheritance rather than by remembering.

  Deliberately **not** exposed over JSON:API or GraphQL. Audit data is read
  through the admin UI and through purpose-built queries, because a generic
  filterable API over the audit log is an information-disclosure surface: it
  reveals the existence and shape of records the caller may not be able to read
  directly.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource AshEnterprise.Audit.EventLog do
      define :latest_event_for_record,
        action: :for_record,
        args: [:resource, :record_id, :attribute],
        not_found_error?: false
    end

    # The archive store and its run record (ADR 0024's age half, `AshEnterprise.Audit.Retention`).
    resource AshEnterprise.Audit.ArchivedEvent do
      define :archived_chain, action: :chain, args: [:organization_id]

      define :latest_archived_event_for_record,
        action: :for_record,
        args: [:resource, :record_id, :attribute],
        not_found_error?: false
    end

    # Read through `AshCompliance.Ownership.Evidence.for_control/3`, with the hot table.
    resource AshEnterprise.Audit.ArchivedEvidence

    # The audit package for one tenant and period, behind its own privilege.
    resource AshEnterprise.Audit.Package do
      define :export_audit_package, action: :export, args: [:from, :to]
    end

    resource AshEnterprise.Audit.ArchiveRun do
      define :record_archive_run, action: :record
      define :list_archive_runs, action: :read
    end

    # How far each chain has been shipped to the OTLP log endpoint (`ExportWorker`).
    resource AshEnterprise.Audit.ExportCursor do
      define :export_cursor, action: :for_chain, args: [:organization_id], not_found_error?: false
      define :list_export_cursors, action: :read
      define :start_export_cursor, action: :start, args: [:chain_organization_id]
      define :advance_export_cursor, action: :advance, args: [:last_sequence, :exported]
      define :fail_export_cursor, action: :fail, args: [:reason]
    end
  end
end
