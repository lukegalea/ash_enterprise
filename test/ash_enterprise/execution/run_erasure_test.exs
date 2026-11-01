defmodule AshEnterprise.Execution.RunErasureTest do
  @moduledoc """
  A clinician asks to be erased while audit retention applies (F11).

  A run about the clinician's file is sealed under the clinician's own erasure scope:
  its input and answer, every journal message, and the arguments and result of each
  tool call that acts on no sealed record of its own. Shredding that scope erases all
  of them at once. The rows, their places in the journal, their transitions and the
  audit hash chain stay; the content reads as erased and `recorded?` is false.

  The model is `AshEnterprise.Test.AssistantFixtures.ScriptedModel` behind the guarded
  ReqLLM module; nothing reaches a network. Jobs are drained by hand.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Execution.Runs

  require Ash.Query

  alias AshEnterprise.Audit.{Chain, EventLog}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.Execution, as: Clinic
  alias AshEnterprise.Test.Execution.ClinicianFile

  @title "SYNTHETIC: Dana Reyes, licence RN-4471, renewal due in March"

  setup do
    in_zone!()
    clinic = clinic!()
    published!(clinic)
    ref = "clinician:#{Ash.UUID.generate()}"

    scope =
      Erasure.ensure_scope!(:data_subject, ref, %{label: "Clinician"},
        actor: SystemActor.system()
      )

    %{clinic: clinic, scope: scope, clinician_file: file!(clinic.nurse, scope)}
  end

  defp file!(member, scope) do
    Clinic.open_clinician_file!("SYNTHETIC: Dana Reyes", scope.id,
      actor: member.actor,
      tenant: member.tenant
    )
  end

  defp about(file), do: %{subject_type: inspect(ClinicianFile), subject_id: file.id}

  defp start_about(member, file) do
    Execution.start_agent_run(
      agent(),
      "SYNTHETIC: note the renewal for Dana Reyes",
      about(file),
      actor: member.actor,
      tenant: member.tenant
    )
  end

  # The run takes its three steps: a tool call, the tool's result, an answer.
  defp complete!(run) do
    assert :waiting = step!(run)
    assert [call] = invocations(run)

    assert {:ok, :succeeded} =
             AshAgent.Invocation.Executor.execute(
               Execution.Invocation,
               call.id,
               oban(run.organization_id)
             )

    assert :completed = step!(run)
    run(run)
  end

  defp steps(run, member) do
    Execution.list_agent_steps!(
      query: [filter: [run_id: run.id], sort: [seq: :asc]],
      load: [:parts, :recorded?],
      actor: member.actor,
      tenant: member.tenant
    )
  end

  # The person who started a run reads its steps; its invocations are read through the
  # grant union, as the clinic's administrator does.
  defp call(run, member) do
    [%{id: id}] = invocations(run)

    Execution.get_invocation!(id,
      load: [:args, :result, :recorded?],
      actor: member.actor,
      tenant: member.tenant
    )
  end

  defp recorded(id) do
    EventLog
    |> Ash.Query.filter(record_id == ^id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(
      &Jason.encode!(%{data: &1.data, changed: &1.changed_attributes, meta: &1.metadata})
    )
  end

  defp shred!(scope),
    do: Erasure.shred_scope!(scope, scope.ref, "the clinician asked", authorize?: false)

  test "a run about a clinician is sealed under the clinician's scope, and so are its steps and tool calls",
       %{clinic: %{nurse: nurse, admin: admin}, scope: scope, clinician_file: file} do
    script!([{:tools, [record_call("note", @title)]}, {:text, ~s({"noted": 1})}])

    {:ok, run} = start_about(nurse, file)
    assert {run.subject_type, run.subject_id} == {inspect(ClinicianFile), file.id}
    assert run.erasure_scope_id == scope.id

    done = complete!(run)
    assert done.status == :completed
    assert journal(run) == [{1, :assistant}, {2, :tool}, {3, :assistant}]

    assert Enum.all?(steps(run, nurse), &(&1.erasure_scope_id == scope.id and &1.recorded?))

    # The note acts on no sealed record of its own, so its arguments are the run's.
    call = call(run, admin)
    assert call.erasure_scope_id == scope.id
    assert call.recorded?
    assert call.args == %{"title" => @title}
  end

  test "shredding the clinician's scope erases the run's content; the rows and the audit chain stay",
       %{
         clinic: %{nurse: nurse, admin: admin, tenant: tenant},
         scope: scope,
         clinician_file: file
       } do
    script!([
      {:tools, [record_call("note", @title)]},
      {:text, ~s({"noted": 1})},
      {:text, ~s({"noted": 0})}
    ])

    {:ok, run} = start_about(nurse, file)
    complete!(run)

    # Another run by the same nurse, about no one, is under the nurse's own scope.
    {:ok, other} = start(nurse)
    assert :completed = step!(other)

    shred!(scope)

    steps = steps(run, nurse)
    assert Enum.map(steps, &{&1.seq, &1.role}) == [{1, :assistant}, {2, :tool}, {3, :assistant}]

    for step <- steps do
      assert %Shredded{erasure_scope_id: scope_id} = step.parts
      assert scope_id == scope.id
      refute step.recorded?
    end

    call = call(run, admin)
    assert call.status == :succeeded
    assert {Shredded.shredded?(call.args), Shredded.shredded?(call.result)} == {true, true}
    refute call.recorded?

    erased = Ash.load!(run(run), [:input, :output], oban(tenant))
    assert {erased.status, erased.step_seq} == {:completed, 3}
    assert {Shredded.shredded?(erased.input), Shredded.shredded?(erased.output)} == {true, true}

    # The other run is not about the clinician, and is untouched.
    assert [%{recorded?: true, parts: [_ | _]}] = steps(other, nurse)

    # Retention: the audit log never held the words, and its chain verifies after the shred.
    for id <- [run.id, call.id], event <- recorded(id), do: refute(event =~ "SYNTHETIC")
    assert recorded(call.id) != []
    assert Chain.verify(tenant).findings == []
    assert Chain.verify(nil).findings == []
  end

  test "a run cannot be about a record its starter cannot read", %{clinic: clinic, scope: scope} do
    admins_file = file!(clinic.admin, scope)

    assert {:error, %Ash.Error.Invalid{} = error} = start_about(clinic.nurse, admins_file)
    assert Exception.message(error) =~ "is not a record the actor can read"
    assert Execution.list_agent_runs!(authorize?: false, tenant: clinic.tenant) == []
  end

  test "nothing new is sealed under a clinician's scope once it is shredded",
       %{clinic: %{nurse: nurse, tenant: tenant}, scope: scope, clinician_file: file} do
    shred!(scope)

    assert {:error, %Ash.Error.Invalid{} = error} = start_about(nurse, file)
    assert Exception.message(error) =~ "has been shredded"
    assert Execution.list_agent_runs!(authorize?: false, tenant: tenant) == []
  end
end
