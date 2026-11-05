defmodule AshEnterprise.Showcase.ReleaseSliceTest do
  @moduledoc """
  Showcase slice 4 below the tour: the licence reader's candidate release on the seeded
  clinic, in recorded mode (`AshEnterprise.Showcase.Release`).

    * the candidate's prompt follows a filing note in a certificate: its injection case
      fails and the gate refuses the release, with the reasons left on the manifest (F9);
    * the routing table changes while a case runs, and the case keeps the version it started
      under (F10);
    * a shadow rerun of the suite causes no effect and activates nobody (F12);
    * a release that covers `activate_credential` changes while an approval waits, and the
      approval is stale when it is decided (F3).

  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Execution
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Case, as: CaseTour
  alias AshEnterprise.Showcase.Release

  setup do
    TestJobs.clear()
    on_exit(&Faults.disarm_all/0)
    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)

    %{
      tenant: admin.tenant,
      clinic: clinic,
      director: actor(clinic.director, admin.tenant),
      coordinator: actor(clinic.coordinator, admin.tenant)
    }
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  # What the runs' `:step` jobs and their tool calls' `:execute` jobs do, until neither
  # queue has anything left, and then the sweep that scores a suite run whose cases settled.
  defp settle!(rounds \\ 12)
  defp settle!(0), do: :ok

  defp settle!(rounds) do
    steps = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    calls = Oban.drain_queue(queue: :execution, with_recursion: true)

    if steps.success + steps.failure + calls.success + calls.failure > 0,
      do: settle!(rounds - 1),
      else:
        AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
  end

  test "the candidate fails its injection case and the gate refuses it (F9)", ctx do
    %{director: director} = ctx

    assert {:ok, _run} = Release.measure(director)
    settle!()

    %{candidate: candidate} = Release.read(director, [])
    assert candidate.run.status == :finished

    assert %{"attack_success_rate" => 1.0, "failed_cases" => ["injected"]} =
             candidate.lanes["injection"]

    assert Enum.sort_by(candidate.results, & &1.case_id) == [
             %{case_id: "injected", status: :failed, tainted: true, injection?: true},
             %{case_id: "plain", status: :passed, tainted: true, injection?: false}
           ]

    assert {:error, error} = Release.request(director)
    assert Exception.message(error) =~ "injection"

    %{candidate: refused} = Release.read(director, [])
    assert refused.manifest.status == :resolved
    assert Enum.any?(refused.problems, &(&1 =~ "injection"))
  end

  test "a shadow rerun runs the same cases with no effect and activates nobody (F12)", ctx do
    %{director: director, tenant: tenant} = ctx
    before = activations(tenant)

    assert {:ok, run} = Release.shadow(director)
    assert run.mode == :shadow
    settle!()

    assert [%{run: finished, calls: calls}] = Release.read(director, []).shadow
    assert finished.status == :finished

    # Every call the cases made was answered from its fixtures, including the one the
    # injected note asked for.
    assert Enum.any?(calls, &String.ends_with?(&1.target, "request_activation"))
    assert Enum.all?(calls, &(&1.simulated? and &1.status == :succeeded))

    assert activations(tenant) == before
    assert Release.read(director, []).candidate == nil
  end

  test "a case keeps the routing table version it started under (F10)", ctx do
    %{coordinator: coordinator, director: director, tenant: tenant, clinic: clinic} = ctx
    [first, second | _] = clinic.credentials

    old = open!(first, coordinator)
    assert {:ok, {"committee", 1}} = Release.route(director, old)

    assert {:ok, %{status: :active}} = Release.change_routing(tenant)
    new = open!(second, coordinator)

    assert {:ok, {"committee", 1}} = Release.route(director, old)
    assert {:ok, {"director", 2}} = Release.route(director, new)

    assert %{table_version: 2, cases: cases} =
             Release.read(director, CaseTour.cases(coordinator)).routing

    assert Map.new(cases, &{&1.number, &1.table_version}) ==
             %{first.number => 1, second.number => 2}

    # The table has no further version.
    assert {:ok, :unchanged} = Release.change_routing(tenant)
  end

  test "a deploy that changes what covers activate_credential leaves the approval stale (F3)",
       ctx do
    %{coordinator: coordinator, director: director, tenant: tenant, clinic: clinic} = ctx
    [credential | _] = clinic.credentials
    opts = [actor: coordinator, tenant: tenant]

    assert {:ok, %{"invocation_id" => id}} = Credentialing.request_activation(credential.id, opts)
    row = Execution.get_invocation!(id, authorize?: false, tenant: tenant)

    %{release: release} = Release.read(director, []).activation
    assert row.release_manifest_id == release.id
    assert row.status == :awaiting_approval

    assert {:ok, %{status: :active} = deployed} = Release.deploy_change(tenant)
    refute deployed.manifest_digest == release.manifest_digest

    task = Ash.load!(row, :approval_task, authorize?: false).approval_task
    committee = actor(hd(clinic.committee), tenant)

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: committee,
      tenant: tenant
    )
    |> Ash.run_action!()

    stale =
      Execution.apply_invocation_decision!(row, actor: SystemActor.oban(), tenant: tenant)

    assert {stale.status, stale.error_code, stale.approved_by_id} ==
             {:stale, "manifest_changed", nil}
  end

  test "the demo build's controls refuse when the fault panel is off", ctx do
    previous = Application.get_env(:ash_enterprise, AshEnterprise.Showcase)

    Application.put_env(
      :ash_enterprise,
      AshEnterprise.Showcase,
      Keyword.put(previous, :fault_controls?, false)
    )

    on_exit(fn -> Application.put_env(:ash_enterprise, AshEnterprise.Showcase, previous) end)

    assert {:error, :fault_controls_off} = Release.deploy_change(ctx.tenant)
    assert {:error, :fault_controls_off} = Release.change_routing(ctx.tenant)
  end

  defp open!(credential, actor) do
    {:ok, %{"instance_id" => id}} = CaseTour.open_case(credential.id, actor)
    id
  end

  defp activations(tenant) do
    Execution.list_invocations!(
      authorize?: false,
      tenant: tenant,
      query: [filter: [target: "AshEnterprise.Credentialing.Credential.activate_credential"]]
    )
    |> Enum.map(&{&1.id, &1.status})
    |> Enum.sort()
  end
end
