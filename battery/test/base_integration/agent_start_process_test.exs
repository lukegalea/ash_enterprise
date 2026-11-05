defmodule Battery.Integration.AgentStartProcessTest do
  @moduledoc """
  Scenario 10 — agent run ↔ process: a run starts a process through an approved invocation.

  An ash_agent run calls the `start_process` tool (`Battery.Execution.StartProcess`), a
  governed target that asks the person the run acts for to confirm
  (`approval: :confirm`) and writes only here. Only a key on the allowlist
  (`Battery.Execution.StartableKey`) may be named.

  Asserted: a key that is not listed is refused where the request is made, with no
  approval task and no instance; before the person confirms there is no instance, the
  request has an approval task for them alone, and it records the active release it is
  bound to; once they confirm and the decision is applied, the target runs once, as
  them, and there is exactly one instance, started by them, on the record named;
  running the row again starts nothing more. The ash_agent run reads the instance's id as
  the tool call's result.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshAgent.Run.Stepper
  alias Battery.Bpmn.{Definition, HumanTask, Instance}
  alias Battery.Execution.{AgentVersion, Invocation, Member, Referral, ReleaseManifest, Run}
  alias Battery.Execution.{RequestApproval, Starter}
  alias Battery.ScriptedModel

  @agent "battery.starter"
  @process "battery_follow_up"

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

  setup_all do
    Enum.each([Battery.Execution.Identity, Battery.Execution.Runtime], &Code.ensure_loaded!/1)
    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    for table <- ~w(battery_agent_steps battery_invocations battery_agent_runs
                    battery_agent_versions battery_members battery_referrals
                    bpmn_task_candidates bpmn_human_tasks bpmn_process_events bpmn_tokens
                    bpmn_instances bpmn_definitions) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    AshBpmn.Runtime.Oban.TestJobs.clear()
    on_exit(&ReleaseManifest.clear/0)

    defn = Definition.create!(%{key: @process, name: "Battery follow-up", xml: @xml})

    Battery.Repo.query!(
      "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
    )

    AgentVersion
    |> Ash.ActionInput.for_action(:register_from_code, %{agent: Starter})
    |> Ash.run_action!()
    |> Ash.Changeset.for_update(:apply_publish, %{})
    |> Ash.update!()

    nurse = Ash.create!(Member, %{name: "Dana (nurse)", role: "nurse"})
    referral = Ash.create!(Referral, %{patient: "SYNTHETIC patient #{unique()}"})
    release = ReleaseManifest.activate(AshAgent.Digest.sha256_hex(%{"release" => unique()}))

    %{nurse: nurse, referral: referral, release: release}
  end

  defp unique, do: System.unique_integer([:positive])

  # A run of the starter agent, started by `nurse`, whose first reply calls the tool for
  # `process` on `referral`, and whose next is `reply`. Returns the run after its first
  # step and the one invocation that step asked for.
  defp asked!(nurse, referral, process, reply) do
    ScriptedModel.script!([
      {:tools,
       [
         {"call_start", "start_process_start",
          %{"input" => %{"process" => process, "subject_id" => referral.id}}}
       ]},
      {:text, reply}
    ])

    run =
      Run
      |> Ash.Changeset.for_create(
        :start,
        %{agent: @agent, input: "SYNTHETIC: start the follow-up for the referral."},
        actor: nurse
      )
      |> Ash.create!()

    assert {:ok, :waiting} = step(run)
    assert [row] = invocations(run)
    {run, row}
  end

  defp step(run), do: Stepper.step(Run, run.id, [])

  defp invocations(run),
    do: Invocation |> Ash.Query.filter(run_id == ^run.id) |> Ash.read!()

  defp current(row), do: Ash.get!(Invocation, row.id)
  defp instances, do: Ash.read!(Instance)

  defp approval_task(row) do
    key = RequestApproval.key()
    id = row.id

    HumanTask
    |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
    |> Ash.Query.load(:candidates)
    |> Ash.read_one!(authorize?: false)
  end

  defp execute(row) do
    Invocation
    |> Ash.ActionInput.for_action(:execute, %{primary_key: %{"id" => row.id}})
    |> Ash.run_action!()
  end

  test "a key that is not on the allowlist is refused before anyone is asked",
       %{nurse: nurse, referral: referral} do
    {_run, row} = asked!(nurse, referral, "battery_billing_run", ~s({"started": false}))

    assert {row.status, row.error_code} ==
             {:rejected,
              "invalid_arguments: process is not a valid Battery.Execution.StartableKey"}

    assert approval_task(row) == nil
    assert instances() == []
  end

  test "no instance before the person confirms, exactly one after, bound to the release",
       %{nurse: nurse, referral: referral, release: release} do
    {run, row} = asked!(nurse, referral, @process, ~s({"started": true}))

    # Asked for, not run: the request waits on the nurse's confirmation, bound to the
    # release that was active, and nothing has started.
    assert {row.status, row.approval_mode} == {:awaiting_approval, :confirm}
    assert row.release_manifest_id == release.id
    assert instances() == []

    task = approval_task(row)
    assert {task.status, task.instance_id} == {:open, nil}
    assert Enum.map(task.candidates, & &1.principal_id) == [nurse.id]

    assert {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: nurse)
    assert instances() == []

    assert {:ok, ready} =
             row |> current() |> Ash.Changeset.for_update(:apply_decision, %{}) |> Ash.update()

    assert ready.status == :ready
    assert instances() == []

    assert execute(ready) == :succeeded

    assert [instance] = instances()
    assert instance.started_by_id == nurse.id
    assert instance.subject_id == referral.id
    assert instance.definition_id == Definition.by_key_version!(@process, 1).id

    done = current(row)
    assert {done.status, done.executing_principal} == {:succeeded, %{type: :person, id: nurse.id}}
    assert %{"value" => %{"instance_id" => instance_id, "process" => @process}} = done.result
    assert instance_id == instance.id

    # Run again, it starts nothing more.
    assert execute(ready) == :skipped
    assert [_one] = instances()

    # The run reads the instance's id as the call's result and finishes.
    assert {:ok, :completed} = step(run)
    assert %{status: :completed} = Ash.get!(Run, run.id)
    assert [_first, second] = ScriptedModel.requests()
    %{content: parts} = Enum.find(second.messages, &(&1.role == :tool))
    assert Enum.map_join(parts, & &1.text) =~ instance.id
  end
end
