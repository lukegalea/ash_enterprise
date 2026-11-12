defmodule AshEnterprise.Audit.ArchivedEvidence do
  @moduledoc """
  Evidence artifacts that have left the hot table (`AshCompliance.Resources.EvidenceArtifact`):
  the archive store for evidence, beside `AshEnterprise.Audit.ArchivedEvent` for the log.

  `AshEnterprise.Audit.Retention.archive/1` moves an artifact here once it is older than the
  hot window (ninety days) **and** a newer artifact exists for the same organization,
  control and collector. The newest artifact of each stays hot whatever its age, because
  the freshness sweep (`AshCompliance.Ownership.Sweep`) reads only the hot table, and an
  annual control's one artifact must not read as missing because it is a hundred days old.

  The columns are the hot table's own, plus `archived_at`, so an archived artifact still
  hashes to its `hash` (`content` is kept). The copy is verified before the hot row is
  deleted: the same count, every column equal, and every stored `content` hashing to its
  `hash`.

  Not a platform resource, for `AshEnterprise.Audit.ArchivedEvent`'s reason: it is a moved
  copy of rows that were written once, and is written only by the set-based copy in
  `AshEnterprise.Audit.Retention`. The trigger refuses every `UPDATE`, and every `DELETE` of
  an artifact collected less than four hundred days ago.
  """

  use Ash.Resource,
    domain: AshEnterprise.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "evidence_artifact_archive"
    repo AshEnterprise.Repo

    custom_indexes do
      index [:organization_id, :control_id, :collected_at],
        name: "evidence_artifact_archive_control_index"
    end

    custom_statements do
      statement :evidence_artifact_archive_guard_function do
        up """
        CREATE OR REPLACE FUNCTION ash_enterprise_evidence_archive_guard() RETURNS trigger AS $fn$
        BEGIN
          IF TG_OP = 'DELETE' AND OLD.collected_at < now() - interval '400 days' THEN
            RETURN OLD;
          END IF;

          RAISE EXCEPTION 'evidence_artifact_archive keeps every artifact for 400 days; % is not permitted', TG_OP
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Archived evidence is never edited, and is purged only after 400 days.';
        END;
        $fn$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS ash_enterprise_evidence_archive_guard();"
      end

      statement :evidence_artifact_archive_guard_trigger do
        up """
        CREATE OR REPLACE TRIGGER evidence_artifact_archive_guard
          BEFORE UPDATE OR DELETE ON evidence_artifact_archive
          FOR EACH ROW EXECUTE FUNCTION ash_enterprise_evidence_archive_guard();
        """

        down "DROP TRIGGER IF EXISTS evidence_artifact_archive_guard ON evidence_artifact_archive;"
      end
    end
  end

  actions do
    defaults [:read]
    default_accept []

    read :for_control do
      argument :organization_id, :uuid, allow_nil?: false
      argument :control_id, :string, allow_nil?: false

      prepare build(sort: [collected_at: :asc])

      filter expr(organization_id == ^arg(:organization_id) and control_id == ^arg(:control_id))
    end
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end

  attributes do
    attribute :id, :uuid do
      primary_key? true
      allow_nil? false
      writable? false
      public? true
    end

    attribute :organization_id, :uuid, allow_nil?: false, writable?: false, public?: true
    attribute :control_id, :string, allow_nil?: false, writable?: false, public?: true
    attribute :subject_type, :string, writable?: false, public?: true
    attribute :subject_id, :string, writable?: false, public?: true
    attribute :hash, :string, allow_nil?: false, writable?: false, public?: true
    attribute :content, :binary, writable?: false, public?: true
    attribute :media_type, :string, allow_nil?: false, writable?: false, public?: true
    attribute :collector, :string, allow_nil?: false, writable?: false, public?: true
    attribute :method, :string, allow_nil?: false, writable?: false, public?: true
    attribute :chain_of_custody, {:array, :map}, writable?: false, public?: true
    attribute :retention_class, :string, writable?: false, public?: true

    attribute :collected_at, :utc_datetime_usec,
      allow_nil?: false,
      writable?: false,
      public?: true

    attribute :inserted_at, :utc_datetime_usec, allow_nil?: false, writable?: false, public?: true

    attribute :archived_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      public? true
      description "When the retention run copied this artifact out of the hot table."
    end
  end
end
