defmodule AshEnterprise.Platform.DemoTenantTest do
  @moduledoc """
  `mix ash_enterprise.demo` is safe on a database that already holds real tenants: it
  creates or refreshes the demo tenant, named by a fixed slug, and nothing else. SYNTHETIC
  data only.
  """

  use AshEnterprise.DataCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, Team, User}
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Clinic, Clinician, Credential, LicenceReader}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Manifests
  alias AshEnterprise.Platform.{DemoData, DemoTenant, Seeder}
  alias AshEnterprise.Quality
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.{Role, UserRole}
  alias AshEnterprise.Showcase.Credentialing, as: Tour

  @tenant_resources [BusinessUnit, Team, Role, UserRole, Clinic, Clinician, Credential]

  # Another organization's tenant, with an administrator and a clinic's records of its own.
  defp real_tenant! do
    n = System.unique_integer([:positive])

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Real clinic group #{n}",
        unique_name: "real-#{n}",
        email: "real-admin-#{n}@example.org"
      )

    actor = AshEnterprise.Test.DailyFixtures.actor(admin)
    opts = [actor: actor, tenant: organization.id]
    clinic = Credentialing.register_clinic!("Real clinic #{n}", opts)

    clinician =
      Credentialing.register_clinician!(
        %{first_name: "Real", last_name: "Person", job_title: "Nurse", clinic_id: clinic.id},
        opts
      )

    Credentialing.record_credential!(
      %{
        kind: :licence,
        number: "REAL-#{n}",
        expires_on: ~D[2030-01-01],
        clinician_id: clinician.id
      },
      opts
    )

    %{organization: organization, admin: admin}
  end

  # Every row of the tenant, as what would differ if anything had touched it.
  defp snapshot(%{organization: organization, admin: admin}) do
    tenant = organization.id

    rows =
      for resource <- @tenant_resources do
        {resource,
         resource
         |> Ash.read!(tenant: tenant, authorize?: false)
         |> Enum.map(&Map.take(&1, [:id, :updated_at, :version_number]))
         |> Enum.sort_by(& &1.id)}
      end

    user = User |> Ash.Query.filter(id == ^admin.id) |> Ash.read_one!(authorize?: false)
    {rows, Map.take(user, [:id, :email, :updated_at, :owning_business_unit_id])}
  end

  defp demo_counts(organization) do
    tenant = organization.id

    for resource <- @tenant_resources, do: Ash.count!(resource, tenant: tenant, authorize?: false)
  end

  test "it creates its own tenant and leaves another tenant's rows exactly as they were" do
    real = real_tenant!()
    before = snapshot(real)

    result = DemoTenant.run!()

    assert result.organization.unique_name |> to_string() == DemoTenant.slug()
    refute result.organization.id == real.organization.id
    assert result.clinic.clinic.name == "Riverside Community Clinic"
    assert snapshot(real) == before
  end

  test "running it twice changes nothing the second time" do
    real = real_tenant!()

    first = DemoTenant.run!()
    demo_rows = demo_counts(first.organization)
    demo_snapshot = snapshot(%{organization: first.organization, admin: elem(admin(first), 0)})
    real_before = snapshot(real)

    second = DemoTenant.run!()

    assert second.organization.id == first.organization.id
    assert demo_counts(second.organization) == demo_rows

    assert snapshot(%{organization: second.organization, admin: elem(admin(first), 0)}) ==
             demo_snapshot

    assert snapshot(real) == real_before
    assert second.counts == first.counts
  end

  test "it refuses to fill any tenant but its own" do
    %{organization: other} = real_tenant!()

    assert_raise ArgumentError, ~r/writes only to the "clinic-demo" tenant/, fn ->
      DemoTenant.populate!(other)
    end

    assert Ash.count!(Clinic, tenant: other.id, authorize?: false) == 1
  end

  test "it does not move a person who already belongs to another tenant" do
    %{organization: other, admin: admin} = real_tenant!()
    other_unit = BusinessUnit |> Ash.read_one!(tenant: other.id, authorize?: false)

    # The demo's own person address, held by someone in another tenant.
    someone = DemoData.ensure_user!("dana@example.com", other_unit, other.id)

    assert_raise ArgumentError, ~r/dana@example.com already belongs to another tenant/, fn ->
      DemoTenant.run!()
    end

    kept = User |> Ash.Query.filter(id == ^someone.id) |> Ash.read_one!(authorize?: false)
    assert kept.owning_business_unit_id == other_unit.id
    assert admin.id != someone.id
  end

  describe "passwords" do
    @tag :tmp_dir
    test "a password file is read when it exists and made, privately, when it does not", %{
      tmp_dir: dir
    } do
      path = Path.join([dir, "nested", "demo.pw"])

      generated = DemoTenant.password_from_file!(path)
      assert byte_size(generated) >= 32
      assert File.read!(path) == generated
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert DemoTenant.password_from_file!(path) == generated

      File.write!(path, "chosen-by-someone\n")
      assert DemoTenant.password_from_file!(path) == "chosen-by-someone"
    end

    test "the demo people sign in with the given password, and not the fixed one" do
      DemoTenant.run!(password: "a-long-private-password")

      assert signs_in?(DemoTenant.admin_email(), "a-long-private-password")
      assert signs_in?("dana@example.com", "a-long-private-password")
      refute signs_in?(DemoTenant.admin_email(), "password1234")
    end

    test "without one the fixed local-development password is kept" do
      DemoTenant.run!()
      assert signs_in?(DemoTenant.admin_email(), "password1234")
    end

    test "a re-run with another password does not reset the people who exist" do
      DemoTenant.run!(password: "first-password-123")
      DemoTenant.run!(password: "second-password-456")

      assert signs_in?(DemoTenant.admin_email(), "first-password-123")
      refute signs_in?(DemoTenant.admin_email(), "second-password-456")
    end

    defp signs_in?(email, password) do
      user = User |> Ash.Query.filter(email == ^email) |> Ash.read_one!(authorize?: false)
      Bcrypt.verify_pass(password, user.hashed_password)
    end
  end

  # The fixed password is public, so only dev and test hand it out (`fixed_seed_password?`
  # in config/dev.exs and config/test.exs). These turn the flag off, as a release has it.
  describe "where the fixed password is not allowed" do
    setup do
      Application.put_env(:ash_enterprise, :fixed_seed_password?, false)
      on_exit(fn -> Application.put_env(:ash_enterprise, :fixed_seed_password?, true) end)
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      :ok
    end

    test "the demo task refuses without a password file, and writes nothing" do
      assert_raise Mix.Error, ~r/password1234.*--password-file PATH/s, fn ->
        Mix.Tasks.AshEnterprise.Demo.run([])
      end

      assert DemoTenant.find() == nil
    end

    test "the seed task refuses without a password, and writes nothing" do
      count = Ash.count!(AshEnterprise.Accounts.Organization, authorize?: false)

      assert_raise Mix.Error, ~r/--password-file PATH/, fn ->
        Mix.Tasks.AshEnterprise.Seed.run([])
      end

      assert Ash.count!(AshEnterprise.Accounts.Organization, authorize?: false) == count
    end

    test "the seeder's own functions refuse before writing too" do
      assert_raise ArgumentError, ~r/--password-file/, fn -> DemoTenant.run!() end
      assert DemoTenant.find() == nil

      n = System.unique_integer([:positive])

      assert_raise ArgumentError, ~r/--password-file/, fn ->
        Seeder.seed_tenant(name: "No password #{n}", unique_name: "no-password-#{n}")
      end

      assert AshEnterprise.Accounts.Organization
             |> Ash.Query.filter(unique_name == ^"no-password-#{n}")
             |> Ash.read!(authorize?: false) == []
    end

    @tag :tmp_dir
    test "the demo task seeds with a password file, and the people sign in with it", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "demo.pw")

      Mix.Tasks.AshEnterprise.Demo.run(["--password-file", path])

      password = File.read!(path)
      assert DemoTenant.find()
      assert signs_in?(DemoTenant.admin_email(), password)
      assert signs_in?("dana@example.com", password)
      refute signs_in?(DemoTenant.admin_email(), "password1234")

      assert_received {:mix_shell, :info, [summary]}
      assert summary =~ "password in #{path}"
      refute summary =~ password
    end
  end

  test "a live reading of the licence reader starts on the released first version, not the candidate" do
    %{organization: organization, clinic: clinic} = DemoTenant.run!()
    tenant = organization.id
    key = LicenceReader.key()

    assert [baseline, candidate] =
             Execution.list_agent_versions!(
               authorize?: false,
               tenant: tenant,
               query: [filter: [key: key, status: :published], sort: [version: :asc]]
             )

    # The baseline is released; the candidate is published and waits for its own release.
    assert {:ok, id} = Manifests.agent_version(key, tenant)
    assert id == baseline.id

    coordinator =
      ActorContext.attach(
        clinic.coordinator,
        ActorContext.build(clinic.coordinator, tenant: tenant)
      )

    assert {:ok, run} = Tour.start_reading(hd(clinic.credentials).id, coordinator)
    assert run.agent_version_id == baseline.id
    refute run.agent_version_id == candidate.id
  end

  test "the comparison shows the candidate better on quality, attacked, and not recommended" do
    %{organization: organization, clinic: clinic, comparison: suite} = DemoTenant.run!()
    tenant = organization.id

    director =
      ActorContext.attach(clinic.director, ActorContext.build(clinic.director, tenant: tenant))

    [first, candidate] =
      Execution.list_agent_versions!(
        authorize?: false,
        tenant: tenant,
        query: [filter: [key: LicenceReader.key(), status: :published], sort: [version: :asc]]
      )

    comparison = Quality.compare_suite_runs!(suite.id, actor: director, tenant: tenant)
    [baseline, measured, imported] = comparison.candidates

    assert {baseline.version, baseline.mode} == {first.version, :adhoc}
    assert {measured.version, measured.mode} == {candidate.version, :offline}
    assert imported.imported
    assert comparison.baseline_id == baseline.id

    outcomes = Map.new(comparison.quality, &{&1.case_id, &1.cells[measured.id].outcome})

    assert outcomes == %{
             "steady" => :passed,
             "improved" => :improved,
             "also_improved" => :improved,
             "degraded" => :degraded,
             "both_fail" => :failed,
             "unmeasured" => :unmeasured
           }

    assert Map.new(comparison.quality, &{&1.case_id, &1.cells[imported.id].outcome}) == %{
             "steady" => :passed,
             "improved" => :skipped,
             "also_improved" => :missing,
             "degraded" => :missing,
             "both_fail" => :missing,
             "unmeasured" => :missing
           }

    assert {baseline.quality.passed, measured.quality.passed} == {2, 3}
    assert {baseline.safety, measured.safety} == {:clear, :failed}

    [injected] = Enum.filter(comparison.safety, &(&1.key == :injection))
    assert injected.cells[measured.id].outcome == :attacked
    assert injected.cells[baseline.id].outcome == :held

    assert {comparison.recommended, comparison.reason} == {baseline.id, :recommended}

    # A second run adds no suite run.
    DemoTenant.run!()

    assert length(
             Quality.compare_suite_runs!(suite.id, actor: director, tenant: tenant).candidates
           ) == 3
  end

  defp admin(result) do
    user =
      User
      |> Ash.Query.filter(email == ^DemoTenant.admin_email())
      |> Ash.read_one!(authorize?: false)

    {user, result}
  end
end
