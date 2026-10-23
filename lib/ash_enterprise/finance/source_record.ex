defmodule AshEnterprise.Finance.SourceRecord do
  @moduledoc """
  The household finance store's raw layer: BIZEV's temporal `SourceRecord`
  (`use AshDiscreteBusinessEvents.Resources, :source_record`) on the
  platform base, one record per Tiller row, its history as periods.

  Identity `(source, stream, external_id, region)`: source `:tiller`, the
  tab as the stream (`:transactions`, `:balance_history`), and
  `"<linked account id>:<row key>"` as the external id
  (`AshEnterprise.Finance.Tiller.Rows` says how a row is keyed). A row whose
  content changes in Tiller — a recategorization, a corrected amount — is a
  new version, the old one keeping its period: exactly the history worth
  keeping. A row that leaves the sheet gets a version saying so.

  ## Sealed, and so shreddable

  `raw_payload` never holds the row in the clear:

      %{"v" => 1, "state" => "present" | "removed",
        "fingerprint" => keyed digest of the row,
        "sealed" => the row, sealed under the linked account's scope}

  (`AshEnterprise.Finance.Sealing`). Sealing uses a fresh IV every time, so
  the bytes of two seals of one row differ; the fingerprint is what says the
  row did not change, and the step lands nothing when it is equal
  (`AshEnterprise.Finance.Tiller.Step`), the same no-op BIZEV's own land
  makes for identical content.

  ## Machinery only

  `tenant?: false` and no person path, for the reasons
  `AshEnterprise.Mdm.SourceRecord` gives: BIZEV's identity knows nothing of
  organizations (the linked account in the external id is what scopes a
  row), so no role grant could be scoped here. The step reads and lands with
  `authorize?: false`; people read the finance store through the ledger,
  which is tenant-scoped and owner-only. `audit?: false`: the temporal
  record is the provenance.

  Not partitioned by month (BIZEV-12's optional retention layout): that is
  a hand-written migration, which this repository does not write.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Finance,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    policies?: false

  use AshDiscreteBusinessEvents.Resources, :source_record

  postgres do
    table "finance_source_records"
    repo AshEnterprise.Repo
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    # No person path: a raw landing is not a person-readable surface, and the
    # grant union cannot scope a row with no organization_id. A policy that
    # never authorizes leaves it so, additively.
    policy always() do
      authorize_if never()
    end
  end
end
