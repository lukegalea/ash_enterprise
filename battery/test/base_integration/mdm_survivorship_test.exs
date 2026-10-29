defmodule Battery.Integration.MdmSurvivorshipTest do
  @moduledoc """
  Scenario 4 — MDM survivorship over business events.

  Raw source records land through the BIZEV SourceRecord path (one record
  per external source, same vendor); the mappings-as-data engine maps each
  landed payload into canonical fields (pure, version-pinned); the mapped
  records feed ash_mdm: the rules-as-data match scores the staged record
  against the golden candidate, the candidate is recorded, and the
  survivorship fold picks per-attribute winners with provenance — which is
  what the golden vendor record is written from.

  Asserted: the golden record's values come from survivorship rules
  applied to EVENT-LANDED records, the provenance names the winning
  source per attribute, and every mapped fact carries the content-hash of
  the active MappingVersion it was mapped with.
  """

  use ExUnit.Case, async: false

  alias AshDiscreteBusinessEvents.Mappings
  alias AshMdm.{Match, Survivorship}
  alias Battery.BusinessEvents.{Host, MappingVersion, SourceRecord}
  alias Battery.Mdm.{MatchCandidate, MatchRuleSet, Vendor}

  require Ash.Query

  @survivorship_policy %{
    "default" => "non_null",
    "attributes" => %{
      "vendor_name" => %{"strategy" => "source_rank"},
      "city" => %{"strategy" => "most_recent"},
      "tier" => %{"strategy" => "source_rank"}
    },
    "source_rank" => ["salesforce", "file_import"]
  }

  @match_rules [
    %{"name" => "name_exact", "kind" => "exact", "fields" => ["vendor_name"], "weight" => 1.0}
  ]

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    # The ledger's immutability trigger forbids DELETE; TRUNCATE is the
    # sanctioned, conspicuous reset.
    Battery.Repo.query!("TRUNCATE ledger_events, ledger_simulation_events")

    for table <-
          ~w(source_records mapping_versions
             battery_mdm_vendors mdm_mappings mdm_match_rule_sets mdm_match_candidates) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    :ok
  end

  test "survivorship over event-landed records writes the golden record" do
    vendor_ref = unique_ref()

    # ── 1. mappings-as-data: publish + validate + activate ────────────────
    sf_version = activate_mapping!(:salesforce_vendor_sync)
    fi_version = activate_mapping!(:file_import_vendor_sync)

    # ── 2. land the same vendor from two sources ──────────────────────────
    sf_record =
      SourceRecord.land!(%{
        source: :salesforce,
        stream: :vendor,
        external_id: vendor_ref,
        region: :us,
        residency_tag: "us",
        raw_payload: %{
          "Id" => vendor_ref,
          "VendorName" => "Meridian Tooling",
          "City" => "Rotterdam",
          "Tier" => "A",
          "SystemModstamp" => "2026-10-01T08:00:00.000+0000"
        },
        source_metadata: %{"adapter" => "stub"},
        cursor: %{"system_modstamp" => "2026-10-01T08:00:00.000+0000"},
        fetched_at: ~U[2026-10-01T08:05:00.000000Z]
      })

    fi_record =
      SourceRecord.land!(%{
        source: :file_import,
        stream: :vendor,
        external_id: vendor_ref,
        region: :us,
        residency_tag: "us",
        raw_payload: %{
          "Id" => vendor_ref,
          "VendorName" => "Meridian Tooling",
          "City" => "Utrecht",
          "Tier" => "B",
          "SystemModstamp" => "2026-10-05T10:00:00.000+0000"
        },
        source_metadata: %{"adapter" => "stub"},
        cursor: %{"batch_seq" => "batch-42"},
        fetched_at: ~U[2026-10-05T10:01:00.000000Z]
      })

    assert sf_record.id != fi_record.id

    # ── 3. map each landed payload (pure, version-pinned) ─────────────────
    {:ok, sf_canonical} =
      Mappings.run(sf_version, sf_record.raw_payload, source_record_id: sf_record.id)

    {:ok, fi_canonical} =
      Mappings.run(fi_version, fi_record.raw_payload, source_record_id: fi_record.id)

    assert sf_canonical.event_kind == :salesforce_vendor_sync
    assert fi_canonical.event_kind == :file_import_vendor_sync

    assert sf_canonical.data == %{
             "vendor_name" => "Meridian Tooling",
             "city" => "Rotterdam",
             "tier" => "A"
           }

    assert fi_canonical.data == %{
             "vendor_name" => "Meridian Tooling",
             "city" => "Utrecht",
             "tier" => "B"
           }

    # provenance joins to the ACTIVE MappingVersion rows, by content hash
    assert sf_canonical.provenance["mapping_version_hash"] == sf_version.version_hash
    assert fi_canonical.provenance["source_record_id"] == fi_record.id

    # ── 4. the mapped records land on the ledger (the land→map→ledger
    #       boundary), each carrying its mapping provenance ────────────────
    for {canonical, record, source} <- [
          {sf_canonical, sf_record, :salesforce},
          {fi_canonical, fi_record, :file_import}
        ] do
      Battery.BusinessEvents.Ledger.record!(%{
        event_kind: canonical.event_kind,
        region: :us,
        residency_tag: "us",
        subject_type: "vendor",
        subject_external_id: vendor_ref,
        subject_stream: :vendor,
        occurred_at: canonical.occurred_at,
        data: canonical.data,
        provenance: canonical.provenance
      })

      assert ledger_provenance_hash(record.id) == active_hash(source)
    end

    # ── 5. match: rules-as-data score the staged record against golden ────
    rule_set =
      MatchRuleSet
      |> Ash.Changeset.for_create(:draft, %{
        golden_resource: "Battery.Mdm.Vendor",
        rules: @match_rules,
        survivorship: @survivorship_policy
      })
      |> Ash.create!(authorize?: false)

    rule_set = Ash.update!(rule_set, %{}, action: :activate, authorize?: false)
    assert rule_set.status == :active

    golden_attrs = sf_canonical.data
    staged_attrs = fi_canonical.data

    {score, explanation} = Match.score(rule_set.rules, staged_attrs, golden_attrs)
    assert Decimal.eq?(score, Decimal.new(1))
    assert explanation["name_exact"]["c"] == Decimal.new(1)

    # ── 6. survivorship: per-attribute winners with provenance ────────────
    records = [
      %{
        record: "salesforce",
        source: "salesforce",
        observed_at: sf_canonical.occurred_at,
        attributes: sf_canonical.data
      },
      %{
        record: "file_import",
        source: "file_import",
        observed_at: fi_canonical.occurred_at,
        attributes: fi_canonical.data
      }
    ]

    %{merged: merged, provenance: provenance} =
      Survivorship.resolve(rule_set.survivorship, records)

    # source_rank: salesforce outranks file_import for name and tier
    assert merged["vendor_name"] == "Meridian Tooling"
    assert provenance["vendor_name"]["source"] == "salesforce"
    assert merged["tier"] == "A"

    # most_recent: the later-observed file import wins the city
    assert merged["city"] == "Utrecht"
    assert provenance["city"]["source"] == "file_import"
    assert provenance["city"]["strategy"] == "most_recent"

    # ── 7. the golden record is written from the fold ─────────────────────
    golden =
      Vendor
      |> Ash.Changeset.for_create(:create, %{
        name: merged["vendor_name"],
        city: merged["city"],
        tier: merged["tier"],
        external_ref: vendor_ref,
        provenance: provenance
      })
      |> Ash.create!(authorize?: false)

    assert golden.name == "Meridian Tooling"
    assert golden.city == "Utrecht"
    assert golden.tier == "A"
    assert golden.provenance["vendor_name"]["source"] == "salesforce"

    # and the golden record's values trace back through the mapped
    # canonical data to the LANDED raw records: every merged attribute is
    # byte-identical to one canonical record's field
    assert merged["vendor_name"] in [
             sf_canonical.data["vendor_name"],
             fi_canonical.data["vendor_name"]
           ]

    assert merged["city"] in [sf_canonical.data["city"], fi_canonical.data["city"]]

    # ── 8. the scored pair is on the record as a match candidate ──────────
    candidate =
      MatchCandidate
      |> Ash.Changeset.for_create(:create, %{
        staged_record_id: fi_record.id,
        golden_resource: "Battery.Mdm.Vendor",
        golden_id: golden.id,
        score: score,
        explanation: explanation
      })
      |> Ash.create!(authorize?: false)

    assert candidate.status == :pending
    assert Decimal.eq?(candidate.score, Decimal.new(1))
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp unique_ref, do: "V-" <> Integer.to_string(System.unique_integer([:positive]))

  defp activate_mapping!(name) do
    {:ok, version} = Mappings.publish(Host, name, MappingVersion)
    assert version.status == :draft

    {:ok, validated} = MappingVersion.validate_version(version)
    activated = Mappings.activate!(validated)

    assert activated.status == :active
    assert Mappings.active_version(MappingVersion, name).version_hash == activated.version_hash

    activated
  end

  defp ledger_provenance_hash(record_id) do
    Battery.BusinessEvents.Ledger
    |> Ash.Query.filter(provenance["source_record_id"] == ^record_id)
    |> Ash.read_one!()
    |> then(& &1.provenance["mapping_version_hash"])
  end

  defp active_hash(source) do
    name =
      case source do
        :salesforce -> :salesforce_vendor_sync
        :file_import -> :file_import_vendor_sync
      end

    Mappings.active_version(MappingVersion, name).version_hash
  end
end
