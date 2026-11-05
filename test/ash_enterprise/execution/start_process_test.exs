defmodule AshEnterprise.Execution.StartProcessTest do
  @moduledoc """
  An agent starts a process (`AshEnterprise.Execution.StartProcess`, ADR 0055): the
  `start_process` tool is a governed target that asks the person the run acts for to
  confirm. Until they do there is no instance; once they do there is exactly one, started
  by them, running the definition the clinic runs and pinned to the active release that
  names it. A process that is not on the allowlist is refused at the request, a record the
  person cannot read stops the start, and so does a process taken off the list while the
  request waited.

  Sandbox; jobs are drained by hand. The model is the scripted one.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Execution.Runs

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Actions.StartProcess, as: StartProcessAction
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.{AutomationPrincipal, Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.{ClinicNote, Releases, Starter}

  @process "clinic.follow_up"
  @other "clinic.billing_run"
  @start "AshEnterprise.Execution.StartProcess.start"

  @xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="P" isExecutable="true">
      <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:endEvent id="E"><bpmn2:incoming>F</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="E"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    in_zone!()
    pause_queues!()
    previous = Application.get_env(:ash_enterprise, :agent_startable_processes)
    Application.put_env(:ash_enterprise, :agent_startable_processes, [@process])

    on_exit(fn ->
      Application.put_env(:ash_enterprise, :agent_startable_processes, previous)
      Resolver.forget_platform_tenant()
    end)

    platform = Seeder.seed_platform_organization()
    Resolver.forget_platform_tenant()
    publish_process!(platform.id, @process)
    publish_process!(platform.id, @other)

    clinic = clinic!()
    note = note!(clinic.nurse, "SYNTHETIC follow-up #{System.unique_integer([:positive])}")
    %{clinic: clinic, note: note}
  end

  defp publish_process!(platform, key) do
    definition =
      Definition.create!(
        %{key: key, name: key, xml: @xml},
        actor: SystemActor.process(),
        tenant: platform
      )

    AshEnterprise.Repo.query!(
      "UPDATE bpmn_definitions SET status = 'published' WHERE id = $1",
      [Ecto.UUID.dump!(definition.id)]
    )
  end

  defp note!(person, title) do
    Ash.create!(ClinicNote, %{title: title},
      action: :record,
      actor: person.actor,
      tenant: person.tenant
    )
  end

  defp args(note, process \\ @process),
    do: %{
      "process" => process,
      "subject_type" => inspect(ClinicNote),
      "subject_id" => note.id
    }

  defp ask(clinic, args, key \\ nil) do
    Execution.invoke(@start, args, %{key: key || "start:#{System.unique_integer([:positive])}"},
      actor: clinic.nurse.actor,
      tenant: clinic.tenant
    )
  end

  defp instances(tenant),
    do: Instance |> Ash.read!(authorize?: false, tenant: tenant)

  # The nurse confirms, the decision is applied, the job runner runs the row.
  defp confirm!(clinic, row) do
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
      actor: DailyFixtures.actor(clinic.nurse.user),
      tenant: clinic.tenant
    )
    |> Ash.run_action!()

    %{status: :ready} =
      ready = Execution.apply_invocation_decision!(row, oban(clinic.tenant))

    {:ok, outcome} = Executor.execute(Invocation, ready.id, oban(clinic.tenant))

    {outcome,
     Execution.get_invocation!(row.id, Keyword.put(oban(clinic.tenant), :load, [:result]))}
  end

  test "before approval there is no instance; after it there is one, pinned to the release",
       %{clinic: clinic, note: note} do
    manifest =
      Releases.release!(clinic, "clinic.follow_up_release", [%{kind: "process", key: @process}])

    {:ok, row} = ask(clinic, args(note))
    assert {row.status, row.approval_mode} == {:awaiting_approval, :confirm}
    assert instances(clinic.tenant) == []

    assert {:succeeded, done} = confirm!(clinic, row)
    assert done.status == :succeeded
    assert %{"instance_id" => instance_id, "process" => @process} = done.result["value"]

    assert [instance] = instances(clinic.tenant)
    assert instance.id == instance_id
    assert instance.started_by_id == clinic.nurse.user.id
    assert instance.subject_id == note.id
    assert instance.release_manifest_id == manifest.id
  end

  test "the same request asked again starts nothing more", %{clinic: clinic, note: note} do
    {:ok, row} = ask(clinic, args(note), "start:once")
    {:succeeded, _done} = confirm!(clinic, row)

    assert {:ok, again} = ask(clinic, args(note), "start:once")
    assert again.id == row.id
    assert {:ok, :skipped} = Executor.execute(Invocation, row.id, oban(clinic.tenant))
    assert [_one] = instances(clinic.tenant)
  end

  test "a process that is not on the allowlist is refused before anyone is asked",
       %{clinic: clinic, note: note} do
    {:ok, row} = ask(clinic, args(note, @other))

    assert row.status == :rejected
    assert row.error_code =~ "process is not a valid"
    assert Ash.load!(row, :approval_task, authorize?: false).approval_task == nil
    assert instances(clinic.tenant) == []
  end

  test "a process taken off the list while the request waited does not start",
       %{clinic: clinic, note: note} do
    {:ok, row} = ask(clinic, args(note))
    Application.put_env(:ash_enterprise, :agent_startable_processes, [])

    assert {:failed, failed} = confirm!(clinic, row)
    assert {failed.status, failed.failure_class} == {:failed, :rejected}
    assert instances(clinic.tenant) == []
  end

  test "a record the person cannot read does not start a process", %{clinic: clinic} do
    hidden = note!(clinic.admin, "SYNTHETIC the audit findings")
    {:ok, row} = ask(clinic, args(hidden))

    assert {:failed, failed} = confirm!(clinic, row)
    assert {failed.status, failed.failure_class} == {:failed, :rejected}
    assert instances(clinic.tenant) == []
  end

  test "an agent's tool call is the same request: the run waits for the nurse's confirmation",
       %{clinic: clinic, note: note} do
    published!(clinic, %{}, Starter)

    script!([
      {:tools, [{"call_start", "start_process_start", %{"input" => args(note)}}]},
      {:text, ~s({"started": true})}
    ])

    {:ok, run} = start(clinic.nurse, "SYNTHETIC: start the follow-up.", "clinic.starter")
    assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)
    assert_receive {:model_request, _messages, tools, _opts}
    assert "start_process_start" in tools
    assert %{failure: 0} = Oban.drain_queue(queue: :execution)

    assert [asked] = invocations(run)
    assert asked.status == :awaiting_approval
    assert instances(clinic.tenant) == []

    assert {:succeeded, _done} = confirm!(clinic, asked)
    assert [_one] = instances(clinic.tenant)
  end

  test "an agent that runs as an automation principal starts no process as the person alone",
       %{clinic: clinic, note: note} do
    # The run's tool call is executed as the principal acting for the nurse, on the
    # intersection of their authority. An instance records only the person who started it,
    # and its service tasks run as that person's whole authority, so it is refused.
    person = clinic.nurse
    principal = AutomationPrincipal.evidence_admitter()

    acting =
      AutomationPrincipal.acting(
        principal,
        person.user.id,
        "clinic.starter",
        ActorContext.intersect(
          ActorContext.build(person.user, tenant: clinic.tenant),
          ActorContext.build_automation(:evidence_admitter, clinic.tenant)
        )
      )

    input = %{arguments: Map.new(args(note), fn {k, v} -> {String.to_existing_atom(k), v} end)}
    context = %Ash.Resource.Actions.Implementation.Context{actor: acting, tenant: clinic.tenant}

    assert {:error, %Ash.Error.Changes.InvalidArgument{field: :process}} =
             StartProcessAction.run(input, [], context)

    assert instances(clinic.tenant) == []
  end
end
