defmodule AshEnterprise.Showcase.HistoryTest do
  @moduledoc """
  `mix ash_enterprise.demo --history` (`AshEnterprise.Showcase.History`): the tour's
  fault-driven beats run once in the demo tenant, through the application's own actions,
  on a database that already holds another tenant. Each beat ends in its failure and is
  reported so; a second run changes nothing; any other tenant is refused before a write; a
  beat that did not end in its failure is reported as not produced, never as produced; no
  fault point stays armed and no job stays held. SYNTHETIC data only.

  The suite's Oban runs on the seed's engine (`HeldJobs`, Basic until something holds), so
  the held path is the one under test; the process engine runs inline, as in every test.
  """

  use AshEnterprise.DataCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  require Ash.Query

  import Ecto.Query, only: [from: 2]

  alias AshEnterprise.Bpmn.{HumanTask, Instance}
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Credential, ReleaseDemoData, RoutingTable}
  alias AshEnterprise.Execution.{Invocation, Run}
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.{DemoTenant, Seeder}
  alias AshEnterprise.Repo
  alias AshEnterprise.Showcase.History

  @demo_resources [Invocation, Run, Instance, HumanTask, Credential]

  setup do
    on_exit(&Faults.disarm_all/0)
    :ok
  end

  defp other_tenant! do
    n = System.unique_integer([:positive])

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Other clinic group #{n}",
        unique_name: "other-#{n}",
        email: "other-admin-#{n}@example.org"
      )

    actor = AshEnterprise.Test.DailyFixtures.actor(admin)
    opts = [actor: actor, tenant: organization.id]
    clinic = Credentialing.register_clinic!("Other clinic #{n}", opts)

    clinician =
      Credentialing.register_clinician!(
        %{first_name: "Other", last_name: "Person", job_title: "Nurse", clinic_id: clinic.id},
        opts
      )

    Credentialing.record_credential!(
      %{
        kind: :licence,
        number: "OTHER-#{n}",
        expires_on: ~D[2030-01-01],
        clinician_id: clinician.id
      },
      opts
    )

    organization
  end

  # Every row of these resources in `tenant`, as what would differ if anything had touched it.
  defp snapshot(tenant) do
    for resource <- @demo_resources do
      {resource,
       resource
       |> Ash.read!(tenant: tenant, authorize?: false)
       |> Enum.map(&Map.take(&1, [:id, :updated_at, :status]))
       |> Enum.sort_by(& &1.id)}
    end
  end

  defp jobs, do: Repo.aggregate("oban_jobs", :count, prefix: Oban.config().prefix)

  defp held_jobs do
    Repo.aggregate(
      from(j in "oban_jobs", where: fragment("? \\? 'held_by'", j.meta)),
      :count,
      prefix: Oban.config().prefix
    )
  end

  defp armed, do: Application.get_env(:ash_enterprise, :__armed_faults__, %{})

  defp statuses(report), do: Map.new(report, &{&1.beat, &1.status})

  test "every beat ends in its failure, in the demo tenant only, and leaves nothing armed or held" do
    other = other_tenant!()
    before = snapshot(other.id)
    %{organization: demo} = DemoTenant.run!()

    report = History.run!(demo)

    assert Enum.map(report, & &1.beat) == History.beats()
    assert statuses(report) == Map.new(History.beats(), &{&1, :produced})
    assert History.complete?(report)
    assert Enum.all?(report, &(&1.ref =~ ~r/^(invocation|run|process_instance):[0-9a-f-]{36}$/))

    assert snapshot(other.id) == before
    assert armed() == %{}
    assert held_jobs() == 0

    by_beat = Map.new(report, &{&1.beat, &1})
    "invocation:" <> f4 = by_beat[3].ref
    "invocation:" <> f2 = by_beat[5].ref
    "run:" <> f1 = by_beat[7].ref

    opts = [authorize?: false, tenant: demo.id]
    assert %{status: :stale, error_code: "subject_changed"} = Ash.get!(Invocation, f4, opts)
    assert %{status: :outcome_unknown} = row = Ash.get!(Invocation, f2, opts)
    refute is_nil(row.resolution_requested_at)

    # F1's run waits on its lease; nothing ran it twice.
    assert %{status: :running} = Ash.get!(Run, f1, opts)
  end

  test "a second run finds every beat and changes nothing" do
    %{organization: demo} = DemoTenant.run!()
    History.run!(demo)
    rows = snapshot(demo.id)
    count = jobs()

    report = History.run!(demo)

    assert statuses(report) == Map.new(History.beats(), &{&1, :already})
    assert History.complete?(report)
    assert snapshot(demo.id) == rows
    assert jobs() == count
  end

  test "filling the demo again does not move its routing table on, so the history still shows F10" do
    DemoTenant.run!()
    %{organization: demo} = DemoTenant.run!()
    assert RoutingTable.latest_version(demo.id) == 1

    report = History.run!(demo)
    assert Enum.find(report, &(&1.beat == 17)).status == :produced
    assert RoutingTable.latest_version(demo.id) == 2
  end

  test "it refuses any tenant but the demo's before it writes" do
    other = other_tenant!()
    before = snapshot(other.id)

    assert_raise ArgumentError, ~r/refusing to write history into .*"clinic-demo" tenant/, fn ->
      History.run!(other)
    end

    assert snapshot(other.id) == before
    assert armed() == %{}
  end

  test "a beat that did not end in its failure is reported so, and the report is not complete" do
    %{organization: demo} = DemoTenant.run!()

    # The routing table already moved on: no case is left on the version before it, so the
    # change F10 shows cannot happen again.
    ReleaseDemoData.change_routing!(demo.id)

    report = History.run!(demo)
    routing = Enum.find(report, &(&1.beat == 17))

    assert {:not_produced, %{older: 2, newer: 2}} = routing.status
    refute History.complete?(report)
    assert armed() == %{}
  end

  test "without fault points, the two beats that arm one are skipped and the others still run" do
    %{organization: demo} = DemoTenant.run!()

    report = History.run!(demo, fault_points?: false)
    statuses = statuses(report)

    assert statuses[5] == {:skipped, :fault_points_compiled_out}
    assert statuses[7] == {:skipped, :fault_points_compiled_out}
    assert Map.drop(statuses, [5, 7]) == Map.new(History.beats() -- [5, 7], &{&1, :produced})
    assert History.complete?(report)
    assert armed() == %{}
  end

  test "complete?/1 reads errored, unmeasured, missing and unknown entries as not complete" do
    done =
      for beat <- History.beats(), do: %{beat: beat, failures: [], status: :produced, ref: nil}

    assert History.complete?(done)

    replace = fn status -> List.replace_at(done, 2, %{Enum.at(done, 2) | status: status}) end

    # errored
    refute History.complete?(replace.({:not_produced, {:failed, :raised}}))
    # unmeasured
    refute History.complete?(replace.(nil))
    # unknown
    refute History.complete?(replace.(:maybe))
    refute History.complete?(replace.({:skipped, :someone_said_so}))
    # missing: a beat left out, an empty report, no report
    refute History.complete?(List.delete_at(done, 0))
    refute History.complete?([])
    refute History.complete?(nil)
    refute History.complete?([%{} | tl(done)])
  end
end
