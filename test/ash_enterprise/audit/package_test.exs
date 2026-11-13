defmodule AshEnterprise.Audit.PackageTest do
  @moduledoc """
  The audit package (`AshEnterprise.Audit.Package`): what an auditor is handed for one
  tenant and one period. Refusals first: a person without the auditor privilege, a
  call in another tenant, and another tenant's rows, which never appear. Then a broken
  chain, which the package reports as broken. Then the OSCAL document, validated
  against NIST's official schema vendored in `priv/vendor/oscal/1.2.3/`, and the files
  the mix task writes.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, brief!: 1]

  alias AshCompliance.Domain, as: Compliance
  alias AshEnterprise.Audit
  alias AshEnterprise.Audit.{ChainVerifyWorker, EventLog, Package}
  alias AshEnterprise.Compliance.FreshnessSweepWorker
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Repo

  @schema_path "priv/vendor/oscal/1.2.3/oscal_assessment-results_schema.json"
  @schema_sha256 "4034e2032332dbf597e59e0646ec16c2c31df992962490371e91f47b219ff42c"

  setup do
    Correlation.start_new()

    ours = tenant!()
    theirs = tenant!()

    %{
      ours: ours,
      theirs: theirs,
      auditor: auditor!(ours),
      their_auditor: auditor!(theirs)
    }
  end

  defp auditor!(admin) do
    member!(admin, "Auditor", [{Package, :read, :global}, {EventLog, :read, :global}])
  end

  defp window do
    now = DateTime.utc_now()
    {DateTime.add(now, -1, :hour), DateTime.add(now, 1, :hour)}
  end

  defp export(person, tenant \\ nil) do
    {from, to} = window()
    Audit.export_audit_package(from, to, actor: person.actor, tenant: tenant || person.tenant)
  end

  # A day's worth of what a tenant's package draws on: a daily chain verification,
  # a freshness sweep (which files findings for every criterion with no evidence) and
  # a review task waiting on a person.
  defp activity!(admin) do
    :ok =
      ChainVerifyWorker.record(AshEvents.Chain.verify(EventLog, admin.tenant), DateTime.utc_now())

    {:ok, _} = FreshnessSweepWorker.sweep(admin.tenant)
    brief!(admin)

    %{
      evidence:
        Enum.map(
          Compliance.evidence_for_control!(admin.tenant, "CC7.2", authorize?: false),
          & &1.id
        ),
      findings:
        Enum.map(Compliance.findings_for_organization!(admin.tenant, authorize?: false), & &1.id),
      tasks:
        Enum.map(
          AshEnterprise.Bpmn.human_tasks_touched_between!(
            elem(window(), 0),
            elem(window(), 1),
            tenant: admin.tenant,
            authorize?: false
          ),
          & &1.id
        )
    }
  end

  describe "refused" do
    test "a person without the auditor privilege is refused, even one who reads the log", ctx do
      reader = member!(ctx.ours, "Log reader", [{EventLog, :read, :global}])
      nobody = member!(ctx.ours, "Nothing", [])

      assert {:error, %Ash.Error.Forbidden{}} = export(reader)
      assert {:error, %Ash.Error.Forbidden{}} = export(nobody)
    end

    test "the privilege cannot be granted narrower than global", ctx do
      # The resource has no rows and no owner, so only `:global` is a legal depth.
      assert_raise Ash.Error.Invalid, fn ->
        member!(ctx.ours, "Local auditor", [{Package, :read, :local}])
      end
    end

    test "an auditor cannot export another tenant", ctx do
      assert {:error, %Ash.Error.Forbidden{}} = export(ctx.auditor, ctx.theirs.tenant)
    end

    test "a period that ends before it starts is refused", ctx do
      {from, to} = window()

      assert {:error, %Ash.Error.Invalid{}} =
               Audit.export_audit_package(to, from,
                 actor: ctx.auditor.actor,
                 tenant: ctx.auditor.tenant
               )
    end
  end

  describe "two tenants" do
    test "another tenant's evidence, findings, tasks and events never appear", ctx do
      ours = activity!(ctx.ours)
      theirs = activity!(ctx.theirs)

      assert theirs.evidence != [] and theirs.findings != [] and theirs.tasks != []

      {:ok, package} = export(ctx.auditor)
      text = Jason.encode!(package)

      for id <- theirs.evidence ++ theirs.findings ++ theirs.tasks ++ [ctx.theirs.tenant] do
        refute text =~ id, "#{id} from the other tenant is in the package"
      end

      # Not vacuous: our own rows are there.
      for id <- ours.evidence ++ ours.findings ++ ours.tasks ++ [ctx.ours.tenant] do
        assert text =~ id
      end

      assert package["manifest"]["tenant"] == ctx.ours.tenant
      assert package["chain"]["events_in_period"] > 0
      assert package["chain"]["events_in_period"] == count_events(ctx.ours.tenant)
    end
  end

  describe "a broken chain" do
    test "is reported as broken, in the bundle and in the OSCAL document", ctx do
      activity!(ctx.ours)
      tamper!(ctx.ours.tenant)

      # The daily verification records a broken chain as evidence like any other run.
      assert :ok =
               ChainVerifyWorker.record(
                 AshEvents.Chain.verify(EventLog, ctx.ours.tenant),
                 DateTime.utc_now()
               )

      {:ok, package} = export(ctx.auditor)

      assert package["chain"]["status"] == "broken"
      assert [%{"problem" => "altered"} | _] = package["chain"]["findings"]
      assert package["chain"]["findings_in_period"] >= 1
      assert package["manifest"]["chain_status"] == "broken"
      assert %{"recorded" => 2, "with_findings" => 1} = package["chain"]["daily_verifications"]

      [result] = package["assessment_results"]["assessment-results"]["results"]

      chain_findings =
        Enum.filter(result["findings"], &(&1["title"] =~ "the audit chain is broken"))

      assert Enum.map(chain_findings, & &1["target"]["target-id"]) ==
               ChainVerifyWorker.evidence_controls()

      for finding <- chain_findings do
        assert finding["target"]["status"]["state"] == "not-satisfied"
        assert finding["target"]["status"]["reason"] == "fail"
      end

      assert :ok = validate(package["assessment_results"])

      # The other tenant's chain is its own, and untouched.
      {:ok, their_package} = export(ctx.their_auditor)
      assert their_package["chain"]["status"] == "intact"
    end
  end

  describe "the OSCAL document" do
    test "the vendored schema is the pinned release file" do
      assert @schema_path |> File.read!() |> sha256() == @schema_sha256
    end

    test "the validator refuses what the schema refuses", ctx do
      root = schema()
      {:ok, %{"assessment_results" => doc}} = export(ctx.auditor)
      assert {:ok, _} = JSV.validate(doc, root)

      # A version 7 UUID, as the database would issue: OSCAL requires 4 or 5.
      bad_uuid = put_in(doc, ["assessment-results", "uuid"], Ash.UUIDv7.generate())
      assert {:error, _} = JSV.validate(bad_uuid, root)

      # A control id that is not a token (the pattern needs Unicode classes to work).
      [result] = doc["assessment-results"]["results"]

      bad_control =
        put_in(doc, ["assessment-results", "results"], [
          put_in(result, ["reviewed-controls", "control-selections"], [
            %{"include-controls" => [%{"control-id" => "6.1"}]}
          ])
        ])

      assert {:error, _} = JSV.validate(bad_control, root)
    end

    test "is valid OSCAL 1.2.3 assessment results, and claims nothing satisfied", ctx do
      ours = activity!(ctx.ours)
      {:ok, package} = export(ctx.auditor)
      doc = package["assessment_results"]

      assert :ok = validate(doc)

      ar = doc["assessment-results"]
      assert ar["metadata"]["oscal-version"] == "1.2.3"
      [result] = ar["results"]

      controls =
        for %{"include-controls" => list} <- result["reviewed-controls"]["control-selections"],
            %{"control-id" => id} <- list,
            do: id

      assert "CC6.1" in controls and "CC7.2" in controls

      # Each artifact collected in the period is an observation.
      observed = Enum.map(result["observations"], & &1["uuid"])

      for id <- ours.evidence do
        assert Audit.Package.Oscal.uuid5("artifact:#{id}") in observed
      end

      # Unknown evidence is a not-satisfied finding; nothing is ever satisfied.
      states = for f <- result["findings"], do: f["target"]["status"]["state"]
      assert states != []
      assert Enum.uniq(states) == ["not-satisfied"]

      # The chain is intact here, so no finding says otherwise.
      assert package["chain"]["status"] == "intact"
      refute Enum.any?(result["findings"], &(&1["title"] =~ "audit chain"))
    end
  end

  describe "the bundle" do
    test "carries criteria, evidence with freshness, findings, reviews and the chain", ctx do
      ours = activity!(ctx.ours)
      {:ok, package} = export(ctx.auditor)

      assert %{"criteria" => criteria, "control_file" => %{"loaded" => true}} =
               package["controls"]

      assert Enum.find(criteria, &(&1["id"] == "CC7.2"))["row"]["id"] == "CC7.2"

      cc72 = Enum.find(package["evidence"]["criteria"], &(&1["id"] == "CC7.2"))
      assert cc72["freshness"]["state"] in ["evidenced", "unknown", "owned"]
      assert [%{"integrity" => "verified", "in_period" => true} | _] = cc72["artifacts"]
      assert Enum.map(cc72["artifacts"], & &1["id"]) == ours.evidence

      assert Enum.sort(Enum.map(package["findings"]["findings"], & &1["id"])) ==
               Enum.sort(ours.findings)

      assert Enum.map(package["reviews"]["tasks"], & &1["id"]) == ours.tasks

      assert [%{"status" => "open", "process" => %{"key" => "morning.brief"}}] =
               package["reviews"]["tasks"]

      assert %{"recorded" => 1, "with_findings" => 0} = package["chain"]["daily_verifications"]
    end

    test "the mix task writes every file and pins each by its hash", ctx do
      activity!(ctx.ours)
      dir = Path.join(System.tmp_dir!(), "audit-package-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {from, to} = window()

      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.AshEnterprise.Audit.Export.run([
          "--tenant",
          ctx.ours.tenant,
          "--as",
          ctx.auditor.email,
          "--from",
          DateTime.to_iso8601(from),
          "--to",
          DateTime.to_iso8601(to),
          "--out",
          dir
        ])
      end)

      manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

      assert Map.keys(manifest["files"]) |> Enum.sort() ==
               ~w(assessment-results.json chain.json controls.json events.csv evidence.json findings.json reviews.json)

      for {name, hash} <- manifest["files"] do
        assert dir |> Path.join(name) |> File.read!() |> sha256() == hash
      end

      assert manifest["events_csv"]["complete"] == true

      assert :ok =
               dir
               |> Path.join("assessment-results.json")
               |> File.read!()
               |> Jason.decode!()
               |> validate()
    end

    test "the mix task refuses a person without the privilege and writes nothing", ctx do
      nobody = member!(ctx.ours, "Nothing", [])
      dir = Path.join(System.tmp_dir!(), "audit-package-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert_raise Mix.Error, ~r/auditor privilege/, fn ->
        Mix.Tasks.AshEnterprise.Audit.Export.run(
          ~w(--tenant #{ctx.ours.tenant} --as #{nobody.email} --from 2026-01-01 --to 2027-01-01 --out #{dir})
        )
      end

      refute File.exists?(dir)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp count_events(tenant) do
    {from, to} = window()

    EventLog
    |> Ash.Query.for_read(:for_export, %{from: from, to: to})
    |> Ash.count!(tenant: tenant, authorize?: false)
  end

  # Edits one of the tenant's events with the immutability trigger off: the escalation
  # the chain is designed to survive (`AshEnterprise.Audit.ChainTest`).
  defp tamper!(tenant) do
    Repo.query!("ALTER TABLE audit_events DISABLE TRIGGER audit_events_immutable")

    Repo.query!(
      "UPDATE audit_events SET action = 'quietly_changed' WHERE organization_id = $1::uuid " <>
        "AND sequence = (SELECT max(sequence) FROM audit_events WHERE organization_id = $1::uuid)",
      [Ecto.UUID.dump!(tenant)]
    )
  after
    Repo.query!("ALTER TABLE audit_events ENABLE TRIGGER audit_events_immutable")
  end

  defp validate(doc) do
    case JSV.validate(doc, schema()) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, JSV.normalize_error(error)}
    end
  end

  # The official schema, read unchanged. Each definition repeats its own location as its
  # `$id`, which JSV refuses as an identifier: such an `$id` is dropped, which changes
  # nothing it resolves to, and any other `$id` fails the test.
  defp schema do
    raw = @schema_path |> File.read!() |> Jason.decode!()

    definitions =
      Map.new(raw["definitions"], fn
        {name, %{"$id" => id} = definition} ->
          if id != "#/definitions/" <> name, do: flunk("unexpected $id #{id} on #{name}")
          {name, Map.delete(definition, "$id")}

        other ->
          other
      end)

    raw |> Map.put("definitions", definitions) |> JSV.build!(formats: true)
  end

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
end
