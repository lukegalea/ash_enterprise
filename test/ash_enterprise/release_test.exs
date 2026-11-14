defmodule AshEnterprise.ReleaseTest do
  @moduledoc """
  The release commands an operator runs where Mix does not exist
  (`bin/ash_enterprise eval "AshEnterprise.Release.audit_verify()"`). A broken chain first:
  the command must say so, not only succeed on a clean one.
  """

  use AshEnterprise.DataCase, async: false

  import ExUnit.CaptureIO
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Audit.{EventLog, Package}
  alias AshEnterprise.Release
  alias AshEnterprise.Repo

  setup do
    AshEnterprise.Platform.Correlation.start_new()
    %{admin: tenant!()}
  end

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

  describe "audit_verify" do
    test "audit_verify reports a broken chain", %{admin: admin} do
      tamper!(admin.tenant)

      out = capture_io(fn -> send(self(), {:report, Release.audit_verify(admin.tenant)}) end)

      assert_received {:report, report}
      assert report.status == :broken
      assert report.findings >= 1
      assert out =~ "quietly_changed" or out =~ "altered"
      assert out =~ "finding(s)"
    end

    test "audit_verify runs without Mix and reports no findings on a clean chain", %{admin: admin} do
      out = capture_io(fn -> send(self(), {:report, Release.audit_verify(admin.tenant)}) end)

      assert_received {:report, report}
      assert report.status == :ok
      assert report.findings == 0
      assert report.checked > 0
      assert out =~ "No breaks"
    end

    test "another tenant's break is not this tenant's finding", %{admin: admin} do
      other = tenant!()
      tamper!(other.tenant)

      capture_io(fn -> send(self(), {:report, Release.audit_verify(admin.tenant)}) end)

      assert_received {:report, %{status: :ok}}
    end
  end

  describe "audit_export" do
    test "refuses a person without the auditor privilege and writes nothing", %{admin: admin} do
      nobody = member!(admin, "Nothing", [])
      dir = Path.join(System.tmp_dir!(), "release-export-#{System.unique_integer([:positive])}")

      {result, err} =
        with_io(:stderr, fn ->
          Release.audit_export(
            tenant: admin.tenant,
            as: nobody.email,
            from: "2026-01-01",
            to: "2027-01-01",
            out: dir
          )
        end)

      assert {:error, message} = result
      assert message =~ "does not hold the auditor privilege"
      assert err =~ "nothing was written"
      refute File.exists?(dir)
    end

    test "writes the package for a person who holds it", %{admin: admin} do
      auditor = member!(admin, "Auditor", [{Package, :read, :global}, {EventLog, :read, :global}])
      dir = Path.join(System.tmp_dir!(), "release-export-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      capture_io(fn ->
        send(
          self(),
          {:result,
           Release.audit_export(
             tenant: admin.tenant,
             as: auditor.email,
             from: "2020-01-01",
             to: "2100-01-01",
             out: dir
           )}
        )
      end)

      assert_received {:result, {:ok, package}}
      assert package["chain"]["status"] == "intact"
      assert File.exists?(Path.join(dir, "manifest.json"))
    end
  end
end
