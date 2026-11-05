defmodule AshEnterprise.Releases.GateTest do
  @moduledoc """
  The release gate (ADR 0058, PLAT-09, F9) and what promotion does.

  A clinic's referral-triage agent is released with the clinic injection suite. New
  instructions that pass the ordinary case and fail the injection case are refused at
  `request_release`, with the reasons left on the manifest; ones that pass both are
  approved by a second administrator, promoted and attested. An approval granted under
  one release does not run under another (F3).
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.Execution.Runs, except: [agent: 0]

  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Quality
  alias AshEnterprise.Security
  alias AshEnterprise.Test.AssistantFixtures
  alias AshEnterprise.Test.Execution.{Authority, NoNetwork, Releases, Starter}
  alias AshEnterprise.Test.Quality.{ClinicInjection, ReferralTriager, ReferralTriagerV2}

  @agent "clinic.referral_triager"
  @read_args %{"input" => %{"patient" => "SYNTHETIC patient 7"}}
  @publish "AshEnterprise.Execution.AgentVersion.apply_publish"
  @promote "AshEnterprise.Execution.ReleaseManifest.promote"

  setup do
    in_zone!()
    pause_queues!()
    :ok = NoNetwork.block!()
    clinic = clinic!()
    Authority.start_grant!(clinic.admin, clinic.admin, @agent)
    %{clinic: clinic}
  end

  defp read_letter, do: {"read", "referral_letters_read_letter", @read_args}

  defp record_note,
    do: {"note", "clinic_note_record", %{"input" => %{"title" => "SYNTHETIC: letter noted"}}}

  defp refer_patient,
    do: {"refer", "referral_board_refer", %{"input" => %{"patient" => "SYNTHETIC patient 99"}}}

  defp script_task! do
    script!([{:tools, [read_letter()]}, {:tools, [record_note()]}, {:text, ~s({"done": true})}])
  end

  defp script_obeys! do
    script!([
      {:tools, [read_letter()]},
      {:tools, [record_note(), refer_patient()]},
      {:text, ~s({"done": true})}
    ])
  end

  defp drive!(run) do
    Enum.reduce_while(1..8, run, fn _round, _run ->
      step!(run)
      Oban.drain_queue(queue: :execution)
      run = run(run)
      if run.status in [:completed, :failed, :cancelled], do: {:halt, run}, else: {:cont, run}
    end)
  end

  defp suite!(clinic) do
    Quality.create_suite_draft!("clinic.injection", %{cases: ClinicInjection.cases()},
      actor: clinic.admin.actor,
      tenant: clinic.tenant
    )
    |> Quality.publish_suite!(actor: clinic.admin.actor, tenant: clinic.tenant)
  end

  # The suite run on `manifest`, each case driven by the script `scripts` gives it.
  defp measure!(clinic, manifest, suite, scripts),
    do: run_suite!(clinic, suite, %{release_manifest_id: manifest.id}, scripts)

  defp run_suite!(clinic, suite, params, scripts) do
    %{admin: admin, tenant: tenant} = clinic

    suite_run =
      Quality.start_suite_run!(suite.id, @agent, params, actor: admin.actor, tenant: tenant)

    for {case_id, script} <- scripts do
      script.()

      [run] =
        Execution.list_agent_runs!(
          query: [filter: [run_key: Quality.SuiteRun.run_key(suite_run.id, case_id, 1)]],
          authorize?: false,
          tenant: tenant
        )

      drive!(run)
    end

    AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
    Quality.get_suite_run!(suite_run.id, oban(tenant))
  end

  defp candidate!(clinic, agent) do
    published!(clinic, %{}, agent)
    suite = suite!(clinic)

    manifest =
      Releases.resolved!(clinic, "clinic.triage", [
        %{kind: "agent", key: @agent},
        %{kind: "suite", key: "clinic.injection"}
      ])

    {manifest, suite}
  end

  test "instructions that follow the letter pass the ordinary case and fail the injection case: refused",
       %{clinic: clinic} do
    published!(clinic, %{}, ReferralTriager)
    {manifest, suite} = candidate!(clinic, ReferralTriagerV2)

    run =
      measure!(clinic, manifest, suite, [
        {"summarise-letter", &script_task!/0},
        {"summarise-letter-injected", &script_obeys!/0}
      ])

    assert run.summary["quality"]["pass_rate"] == 1.0
    assert run.candidate_digest == manifest.manifest_digest

    assert {:error, %Ash.Error.Invalid{} = error} = Releases.request(clinic, manifest)
    assert Exception.message(error) =~ "injection case(s) failed (summarise-letter-injected)"
    assert Exception.message(error) =~ "1 hard failure"

    # Nothing was asked of anyone, the manifest stays resolved, and the reasons stay on it.
    refuted = Releases.reload(clinic, manifest)
    assert refuted.status == :resolved
    assert refuted.gate_result["passed"] == false
    assert Enum.any?(refuted.gate_result["problems"], &(&1 =~ "injection"))

    assert Execution.list_invocations!(
             query: [filter: [target: @promote]],
             authorize?: false,
             tenant: clinic.tenant
           ) == []
  end

  test "a manifest that has not been measured is refused, and so is an agent with no suite",
       %{clinic: clinic} do
    {manifest, _suite} = candidate!(clinic, ReferralTriager)

    assert {:error, error} = Releases.request(clinic, manifest)
    assert Exception.message(error) =~ "no finished offline run on this manifest"

    agent_only = Releases.resolved!(clinic, "clinic.agent_only", [%{kind: "agent", key: @agent}])
    assert {:error, error} = Releases.request(clinic, agent_only)
    assert Exception.message(error) =~ "pin a suite"
  end

  test "an adhoc suite run never satisfies the gate", %{clinic: clinic} do
    version = published!(clinic, %{}, ReferralTriager)
    suite = suite!(clinic)

    manifest =
      Releases.resolved!(clinic, "clinic.triage", [
        %{kind: "agent", key: @agent},
        %{kind: "suite", key: "clinic.injection"}
      ])

    # A run that tries the published version, clean on every case, is not a measurement of
    # the manifest: it cannot even be tied to one.
    assert {:error, error} =
             Quality.start_suite_run(
               suite.id,
               @agent,
               %{mode: :adhoc, agent_version_id: version.id, release_manifest_id: manifest.id},
               actor: clinic.admin.actor,
               tenant: clinic.tenant
             )

    assert Exception.message(error) =~ "offline suite run only"

    adhoc =
      run_suite!(clinic, suite, %{mode: :adhoc, agent_version_id: version.id}, [
        {"summarise-letter", &script_task!/0},
        {"summarise-letter-injected", &script_task!/0}
      ])

    assert {adhoc.mode, adhoc.status} == {:adhoc, :finished}
    assert adhoc.summary["quality"]["pass_rate"] == 1.0

    assert {:error, error} = Releases.request(clinic, manifest)
    assert Exception.message(error) =~ "no finished offline run on this manifest"
  end

  test "a manifest that passes is approved by a second administrator, promoted and attested",
       %{clinic: clinic} do
    {manifest, suite} = candidate!(clinic, ReferralTriager)

    run =
      measure!(clinic, manifest, suite, [
        {"summarise-letter", &script_task!/0},
        {"summarise-letter-injected", &script_task!/0}
      ])

    assert {:ok, asked} = Releases.request(clinic, manifest)
    requested = Releases.reload(clinic, manifest)
    assert {requested.status, requested.gate_result["passed"]} == {:requested, true}
    assert requested.suite_run_ids == [run.id]

    # The author is not asked to approve their own release.
    row =
      Execution.get_invocation!(asked["invocation_id"], authorize?: false, tenant: clinic.tenant)

    assert row.status == :awaiting_approval

    assert %{status: :ready} = Releases.approve!(clinic, asked)

    {:ok, :succeeded} =
      AshAgent.Invocation.Executor.execute(Execution.Invocation, row.id, oban(clinic.tenant))

    active = Releases.reload(clinic, manifest)
    assert active.status == :active

    assert [%{id: id}] =
             Execution.active_release_manifests!(authorize?: false, tenant: clinic.tenant)

    assert id == manifest.id

    statement =
      Execution.export_release_attestation!(manifest.id,
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    assert statement["_type"] == "https://in-toto.io/Statement/v1"
    assert hd(statement["subject"])["digest"] == %{"sha256" => manifest.manifest_digest}
    assert statement["predicate"]["gate"]["passed"] == true
    assert statement["predicate"]["status"] == "active"
  end

  test "a candidate published after a release is not live until a release promotes it",
       %{clinic: clinic} do
    # The release: the triager, measured on the injection suite, approved and promoted.
    {released, suite} = candidate!(clinic, ReferralTriager)

    measure!(clinic, released, suite, [
      {"summarise-letter", &script_task!/0},
      {"summarise-letter-injected", &script_task!/0}
    ])

    {:ok, asked} = Releases.request(clinic, released)
    %{status: :ready} = row = Releases.approve!(clinic, asked)

    {:ok, :succeeded} =
      AshAgent.Invocation.Executor.execute(Execution.Invocation, row.id, oban(clinic.tenant))

    assert Releases.reload(clinic, released).status == :active

    [live] = released.entries |> Enum.filter(&(&1["annotations"]["kind"] == "agent"))
    live_id = live["annotations"]["id"]

    # A candidate is published (four eyes) and fails its gate: it never becomes live.
    candidate = published!(clinic, %{}, ReferralTriagerV2)
    refute candidate.id == live_id

    script_task!()

    {:ok, run} =
      Execution.start_agent_run(@agent, "SYNTHETIC: triage the letter", %{},
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    assert run.agent_version_id == live_id
  end

  test "a suite that sets no threshold still refuses a candidate that fails its ordinary cases",
       %{clinic: clinic} do
    published!(clinic, %{}, ReferralTriager)
    version = published!(clinic, %{}, ReferralTriagerV2)

    suite =
      Quality.create_suite_draft!(
        "clinic.ordinary",
        %{cases: Enum.take(ClinicInjection.cases(), 1)},
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )
      |> Quality.publish_suite!(actor: clinic.admin.actor, tenant: clinic.tenant)

    manifest =
      Releases.resolved!(clinic, "clinic.triage_ordinary", [
        %{kind: "agent", key: @agent},
        %{kind: "suite", key: "clinic.ordinary"}
      ])

    assert version.key == @agent

    # The candidate answers without reading the letter or recording a note: every ordinary
    # case fails and nothing the suite calls a hard failure happens.
    run =
      measure!(clinic, manifest, suite, [
        {"summarise-letter", fn -> script!([{:text, ~s({"done": true})}]) end}
      ])

    assert run.summary["quality"]["pass_rate"] == 0.0
    assert run.summary["safety"]["hard_failures"] == 0

    assert {:error, error} = Releases.request(clinic, manifest)
    assert Exception.message(error) =~ "ordinary case"
    assert Releases.reload(clinic, manifest).status == :resolved
  end

  test "a manifest of several agents is released only when each was measured", %{clinic: clinic} do
    {_manifest, suite} = candidate!(clinic, ReferralTriager)
    published!(clinic, %{}, Starter)

    manifest =
      Releases.resolved!(clinic, "clinic.two_agents", [
        %{kind: "agent", key: @agent},
        %{kind: "agent", key: "clinic.starter"},
        %{kind: "suite", key: "clinic.injection"}
      ])

    assert manifest.id

    measure!(clinic, manifest, suite, [
      {"summarise-letter", &script_task!/0},
      {"summarise-letter-injected", &script_task!/0}
    ])

    assert {:error, error} = Releases.request(clinic, manifest)
    assert Exception.message(error) =~ "agent clinic.starter"
    assert Exception.message(error) =~ "no suite run measured"
  end

  test "a new tenant's Administrator may read and write release manifests; a member with no role may not" do
    seeded = Seeder.seed_tenant(unique_name: "release-#{System.unique_integer([:positive])}")
    name = inspect(Execution.ReleaseManifest)

    granted =
      Security.RolePrivilege
      |> Ash.Query.filter(role_id == ^seeded.role.id and privilege.resource_name == ^name)
      |> Ash.Query.load(:privilege)
      |> Ash.read!(actor: SystemActor.seed(), tenant: seeded.organization.id)
      |> Enum.map(& &1.privilege.access_right)

    for right <- [:read, :create, :write], do: assert(right in granted)

    admin = AssistantFixtures.tenant!()
    member = AssistantFixtures.colleague!(admin, [])
    request = [%{kind: "tool", key: @publish}]

    assert {:error, %Ash.Error.Forbidden{}} =
             Execution.create_release_draft(%{key: "clinic.none", requests: request},
               actor: member.actor,
               tenant: member.tenant
             )

    assert Execution.list_release_manifests!(actor: member.actor, tenant: member.tenant) == []
  end

  test "only the author asks, so the approval excludes them", %{clinic: clinic} do
    manifest =
      Releases.resolved!(clinic, "clinic.tools", [
        %{kind: "tool", key: "AshEnterprise.Test.Execution.ClinicNote.record"}
      ])

    assert {:error, error} =
             Execution.request_release(manifest.id,
               actor: clinic.approver.actor,
               tenant: clinic.tenant
             )

    assert Exception.message(error) =~ "only its author asks"
  end

  test "an approval granted under one release does not run under another (F3)", %{clinic: clinic} do
    draft =
      Execution.register_agent_from_code!(ReferralTriager,
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    one = Releases.release!(clinic, "clinic.publishing", [%{kind: "tool", key: @publish}])
    assert one.status == :active

    %{"invocation_id" => id} =
      Execution.request_agent_publish!(draft.id, %{},
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    row = Execution.get_invocation!(id, authorize?: false, tenant: clinic.tenant)
    assert [%{"manifest_digest" => bound}] = row.authorization_details
    assert {bound, row.release_manifest_id} == {one.manifest_digest, one.id}

    # The release changes while the approval waits: another entry, another digest.
    two =
      Releases.release!(clinic, "clinic.publishing", [
        %{kind: "tool", key: @publish},
        %{kind: "tool", key: "AshEnterprise.Test.Execution.ClinicNote.record"}
      ])

    assert two.status == :active
    assert Releases.reload(clinic, one).status == :superseded
    refute two.manifest_digest == one.manifest_digest

    stale = Releases.approve!(clinic, %{"invocation_id" => id})

    assert {stale.status, stale.error_code, stale.approved_by_id} ==
             {:stale, "manifest_changed", nil}
  end

  test "rolling back makes the earlier manifest active again",
       %{clinic: clinic} do
    one = Releases.release!(clinic, "clinic.rollback", [%{kind: "tool", key: @publish}])

    two =
      Releases.release!(clinic, "clinic.rollback", [
        %{kind: "tool", key: @publish},
        %{kind: "tool", key: "AshEnterprise.Test.Execution.ClinicNote.record"}
      ])

    assert {Releases.reload(clinic, one).status, two.status} == {:superseded, :active}

    back =
      Execution.rollback_release!(Releases.reload(clinic, one), %{},
        actor: clinic.admin.actor,
        tenant: clinic.tenant
      )

    assert back.status == :active
    assert Releases.reload(clinic, two).status == :rolled_back

    assert [%{id: id}] =
             Execution.active_release_manifests!(authorize?: false, tenant: clinic.tenant)

    assert id == one.id
  end

  test "promote runs only as its approved invocation", %{clinic: clinic} do
    manifest = Releases.resolved!(clinic, "clinic.direct", [%{kind: "tool", key: @publish}])

    assert {:error, error} =
             Execution.promote_release(manifest, %{},
               actor: clinic.admin.actor,
               tenant: clinic.tenant
             )

    assert Exception.message(error) =~ "invocation" or error.__struct__ == Ash.Error.Invalid
    assert Releases.reload(clinic, manifest).status == :resolved
  end
end
