defmodule AshEnterprise.Audit.PackageTest do
  @moduledoc """
  The audit package (`AshEnterprise.Audit.Package`): what an auditor is handed for one
  tenant and one period. Refusals first: a person without the auditor privilege, a
  call in another tenant, and another tenant's rows, which never appear. Then a broken
  chain, which the package reports as broken. Then the OSCAL document, built by
  `AshCompliance.Oscal.AssessmentResults` with this application's own observations and
  findings, valid against NIST's official schema and keeping the identifiers this
  application has always derived, and the files the mix task writes.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, brief!: 1]

  alias AshCompliance.Domain, as: Compliance
  alias AshCompliance.Oscal.AssessmentResults
  alias AshEnterprise.Audit
  alias AshEnterprise.Audit.{ChainVerifyWorker, EventLog, Package}
  alias AshEnterprise.Compliance.FreshnessSweepWorker
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Repo

  @ns "urn:ash-enterprise:audit-package"

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
    export_period(person, from, to, tenant)
  end

  defp export_period(person, from, to, tenant \\ nil) do
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

      # The chain's verdict is an observation of its own, its status in our namespace.
      chain_observation =
        Enum.find(result["observations"], &(&1["title"] == "Audit chain verification"))

      assert chain_observation["methods"] == ["TEST"]

      assert %{"name" => "chain-status", "ns" => @ns, "value" => "broken"} in chain_observation[
               "props"
             ]

      # The other tenant's chain is its own, and untouched.
      {:ok, their_package} = export(ctx.their_auditor)
      assert their_package["chain"]["status"] == "intact"
    end
  end

  describe "the OSCAL document" do
    test "is valid OSCAL, with the chain, the reviews and a broken chain's findings", ctx do
      activity!(ctx.ours)
      tamper!(ctx.ours.tenant)

      {:ok, package} = export(ctx.auditor)
      doc = package["assessment_results"]
      [result] = doc["assessment-results"]["results"]

      # This application's own observations and findings are in it, not only the
      # compliance plane's.
      titles = Enum.map(result["observations"], & &1["title"])
      assert "Audit chain verification" in titles
      assert "Review tasks" in titles
      assert Enum.any?(result["findings"], &(&1["title"] =~ "the audit chain is broken"))

      assert :ok = AssessmentResults.validate(doc)
      # As the mix task writes it.
      assert :ok = doc |> Jason.encode!() |> Jason.decode!() |> AssessmentResults.validate()
    end

    test "keeps every identifier this application has always derived", ctx do
      activity!(ctx.ours)
      tamper!(ctx.ours.tenant)
      {from, to} = window()

      {:ok, package} = export_period(ctx.auditor, from, to)

      tenant = ctx.ours.tenant
      %{"period" => %{"from" => f, "to" => t}, "generated_at" => at} = package["manifest"]
      as_of = package["manifest"]["freshness_as_of"]
      chain = package["chain"]
      criteria = package["evidence"]["criteria"]
      key = "#{tenant}:#{f}:#{t}:#{at}"

      observations =
        for(c <- criteria, a <- c["artifacts"], a["in_period"], do: "artifact:#{a["id"]}") ++
          for(c <- criteria, c["freshness"], do: "freshness:#{tenant}:#{c["id"]}:#{as_of}") ++
          ["chain:#{chain["verified_at"]}:#{chain["checked"]}", "reviews:#{tenant}:#{f}:#{t}"]

      findings =
        for(
          c <- criteria,
          c["freshness"] && c["freshness"]["state"] == "unknown",
          do: "freshness-finding:#{c["id"]}:#{c["freshness"]["detail"]}"
        ) ++
          for(
            x <- package["findings"]["findings"],
            x["subject_type"] != "evidence_freshness",
            x["status"] != "compliant",
            do: "finding:#{x["id"]}"
          ) ++
          for(
            c <- ChainVerifyWorker.evidence_controls(),
            do: "chain-finding:#{c}:#{chain["verified_at"]}"
          )

      assert chain["status"] == "broken"
      ar = package["assessment_results"]["assessment-results"]
      [result] = ar["results"]

      assert ar["uuid"] == uuid5("assessment-results:" <> key)
      assert result["uuid"] == uuid5("result:" <> key)
      assert Enum.map(result["observations"], & &1["uuid"]) == Enum.map(observations, &uuid5/1)
      assert Enum.map(result["findings"], & &1["uuid"]) == Enum.map(findings, &uuid5/1)
    end

    test "names the organization, in this application's namespace", ctx do
      {:ok, package} = export(ctx.auditor)
      [result] = package["assessment_results"]["assessment-results"]["results"]

      assert result["props"] == [
               %{"name" => "organization", "ns" => @ns, "value" => ctx.ours.tenant}
             ]

      assert result["title"] == "Evidence, findings, reviews and audit-chain verification"
      assert result["description"] =~ "Assessment results for one organization over ["
    end

    test "is OSCAL 1.2.3 assessment results, and claims nothing satisfied", ctx do
      ours = activity!(ctx.ours)
      {:ok, package} = export(ctx.auditor)
      doc = package["assessment_results"]

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
        assert uuid5("artifact:#{id}") in observed
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

      assert %{"assessment-results" => %{"metadata" => %{"oscal-version" => "1.2.3"}}} =
               dir |> Path.join("assessment-results.json") |> File.read!() |> Jason.decode!()
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

  # RFC 4122 version 5 over the URL namespace: how this application has always named
  # the package's OSCAL identifiers. Written out here, not borrowed from the builder, so
  # the test pins the identifiers rather than whichever function derives them.
  defp uuid5(name) do
    namespace = Ecto.UUID.dump!("6ba7b811-9dad-11d1-80b4-00c04fd430c8")

    <<a::48, _version::4, b::12, _variant::2, c::62>> =
      binary_part(:crypto.hash(:sha, namespace <> name), 0, 16)

    Ecto.UUID.load!(<<a::48, 5::4, b::12, 2::2, c::62>>)
  end

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
end
