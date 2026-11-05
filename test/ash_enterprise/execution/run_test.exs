defmodule AshEnterprise.Execution.RunTest do
  @moduledoc """
  Agent runs (ADR 0056) on the platform base: who may start one and what it pins, a run
  driven end to end by its `:step` jobs through a governed tool call, where its model
  calls are recorded, and how its rows are owned, sealed and read.

  The model is `AshEnterprise.Test.AssistantFixtures.ScriptedModel` behind the guarded
  ReqLLM module; nothing reaches a network. Jobs are drained by hand.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.Execution.Runs

  require Ash.Query

  alias AshAgent.Invocation.{Executor, NoPrincipal}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Invocation, Run, Step}
  alias AshEnterprise.Execution.Run.StepWorker
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Test.Execution, as: Notes

  setup do
    in_zone!()
    clinic = clinic!()
    %{clinic: clinic, version: published!(clinic)}
  end

  defp notes(tenant, title) do
    Notes.list_notes!(query: [filter: [title: title]], tenant: tenant, authorize?: false)
  end

  describe "start" do
    test "pins the latest published version, runs as the requester and queues the first step",
         %{clinic: %{nurse: nurse}, version: version} do
      assert {:ok, run} = start(nurse)

      assert run.status == :queued
      assert run.agent_version_id == version.id
      assert run.owner_id == nurse.user.id
      assert run.executing_principal == %{type: :person, id: nurse.user.id}
      assert run.budget_limit == 20_000
      assert DateTime.diff(run.deadline_at, DateTime.utc_now(), :minute) in 29..30
      assert is_binary(run.correlation_id)

      # Sealed under the requester's own scope; no plaintext column.
      scope = Erasure.get_scope!(run.erasure_scope_id, authorize?: false)
      assert scope.ref == "invocation_requester:#{nurse.user.id}"
      refute run.encrypted_input =~ "SYNTHETIC"

      assert_enqueued(worker: StepWorker, args: %{"primary_key" => %{"id" => run.id}})
    end

    test "a version published with an automation authority runs as that principal, for the requester",
         %{clinic: clinic} do
      # Version 2, the same agent with another prompt, published to act as a principal.
      on_exit(fn -> Application.delete_env(:ash_enterprise, :note_taker_instructions) end)

      Application.put_env(
        :ash_enterprise,
        :note_taker_instructions,
        "Record the note, and its date."
      )

      authority = %{"type" => "automation", "name" => "evidence_admitter"}
      version = published!(clinic, %{authority: authority})
      assert version.version == 2

      assert {:ok, run} = start(clinic.nurse)
      assert run.agent_version_id == version.id

      assert run.executing_principal == %{
               type: :automation,
               id: "evidence_admitter",
               on_behalf_of: clinic.nurse.user.id,
               agent: agent()
             }
    end

    test "is refused to a member without the agent's start grant, and writes nothing",
         %{clinic: clinic} do
      other = AshEnterprise.Test.AssistantFixtures.colleague!(clinic.admin, [])

      assert {:error, %Ash.Error.Forbidden{errors: errors}} = start(other)

      assert [%NoPrincipal{reason: :no_start_grant}] =
               Enum.filter(errors, &match?(%NoPrincipal{}, &1))

      assert Execution.list_agent_runs!(authorize?: false, tenant: clinic.tenant) == []
    end
  end

  describe "a run driven by its jobs" do
    test "a governed tool call is an invocation the run waits for; its result is what the model reads",
         %{clinic: %{nurse: nurse, tenant: tenant}} do
      title = "SYNTHETIC: call the lab about the morning panel"

      script!([
        {:tools, [record_call("call_lab", title)]},
        {:text, ~s({"recorded": 1})}
      ])

      {:ok, run} = start(nurse)

      # The first step: the model asks for the tool; the call is requested, not run.
      assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)
      assert_receive {:model_request, _messages, ["clinic_note_record"], _opts}

      waiting = run(run)
      assert {waiting.status, waiting.blocked_on} == {:waiting, :tools}
      assert notes(tenant, title) == []

      assert [call] = invocations(run)
      assert call.invocation_key == "run:#{run.id}:1:call_lab"
      assert call.target == "AshEnterprise.Test.Execution.ClinicNote.record"
      assert {call.run_id, call.owner_id} == {run.id, nurse.user.id}
      assert call.executing_principal == run.executing_principal

      # The invocation runs as the nurse, once, and wakes the run.
      assert %{failure: 0} = Oban.drain_queue(queue: :execution)
      assert [_note] = notes(tenant, title)
      assert_enqueued(worker: StepWorker, args: %{"primary_key" => %{"id" => run.id}})

      # The next step reads the recorded result and answers.
      assert %{success: 1} = Oban.drain_queue(queue: :agent_runs)
      assert_receive {:model_request, messages, _tools, _opts}
      assert Enum.any?(messages, &(&1.role == :tool))

      done = run(run)
      assert done.status == :completed
      assert Ash.load!(done, [:output], oban(tenant)).output == %{"value" => %{"recorded" => 1}}
      assert journal(run) == [{1, :assistant}, {2, :tool}, {3, :assistant}]
      assert length(notes(tenant, title)) == 1

      # Each model call is recorded under the run and the journal position it filled.
      assert model_calls(run) == [{"run:#{run.id}:1", :ok}, {"run:#{run.id}:3", :ok}]
    end
  end

  describe "a revoked start grant" do
    # A run executing as its requester (the default authority) is held to the agent's
    # start grant at every step and every tool call, as an automation authority's is.
    defp revoke_start_grants!(%{admin: admin, tenant: tenant}) do
      for grant <- Security.AgentStartGrant.read!(actor: admin.actor, tenant: tenant) do
        Security.AgentStartGrant.destroy!(grant, actor: admin.actor, tenant: tenant)
      end

      assert Security.AgentStartGrant.read!(actor: admin.actor, tenant: tenant) == []
    end

    test "stops a run executing as its requester at its next step, before any model call",
         %{clinic: clinic} do
      script!([{:text, ~s({"recorded": 0})}])
      {:ok, run} = start(clinic.nurse)

      revoke_start_grants!(clinic)
      step!(run)

      failed = run(run)
      assert {failed.status, failed.failure_class} == {:failed, :denied}
      assert failed.error_code == "no_authority: no_start_grant"
      refute_received {:model_request, _messages, _tools, _opts}
      assert model_calls(run) == []
      assert invocations(run) == []
    end

    test "denies a tool call the run already requested, before its target is tried",
         %{clinic: %{tenant: tenant} = clinic} do
      title = "SYNTHETIC: order the flu vaccines"
      script!([{:tools, [record_call("order", title)]}])
      {:ok, run} = start(clinic.nurse)

      step!(run)
      assert [%{status: :ready} = call] = invocations(run)
      assert call.executing_principal == %{type: :person, id: clinic.nurse.user.id}

      revoke_start_grants!(clinic)

      assert {:ok, :failed} = Executor.execute(Invocation, call.id, oban(tenant))
      denied = Execution.get_invocation!(call.id, oban(tenant))
      assert {denied.status, denied.failure_class} == {:failed, :denied}
      assert denied.error_code == "no_authority: no_start_grant"
      assert notes(tenant, title) == []
    end
  end

  describe "the journal" do
    test "takes the run's owner and erasure scope, and is sealed", %{clinic: %{nurse: nurse}} do
      script!([{:text, ~s({"recorded": 0})}])
      {:ok, run} = start(nurse)
      assert :completed = step!(run)

      [step] =
        Step
        |> Ash.Query.filter(run_id == ^run.id)
        |> Ash.read!(authorize?: false, tenant: nurse.tenant)

      assert step.owner_id == nurse.user.id
      assert step.erasure_scope_id == run(run).erasure_scope_id
      refute step.encrypted_parts =~ "recorded"
    end

    test "is appended only by its run's record", %{clinic: %{nurse: nurse}} do
      {:ok, run} = start(nurse)

      append =
        &Ash.Changeset.for_create(Step, :append, %{run_id: run.id, seq: 1, role: :user}, &1)

      # Not by the person who started the run, and not by the job runner past the run.
      assert {:error, _refused} = Ash.create(append.(actor: nurse.actor, tenant: nurse.tenant))
      assert {:error, %Ash.Error.Invalid{} = error} = Ash.create(append.(oban(nurse.tenant)))
      assert Exception.message(error) =~ "only its run appends a step"
      assert journal(run) == []
    end
  end

  describe "who reads and changes a run" do
    test "the person who started it reads it and its steps; another member reads neither",
         %{clinic: clinic} do
      script!([{:text, ~s({"recorded": 0})}])
      {:ok, run} = start(clinic.nurse)
      assert :completed = step!(run)
      other = AshEnterprise.Test.AssistantFixtures.colleague!(clinic.admin, [])

      read = fn member, resource ->
        Ash.read!(resource, actor: member.actor, tenant: member.tenant) |> Enum.map(& &1.id)
      end

      assert read.(clinic.nurse, Run) == [run.id]
      assert length(read.(clinic.nurse, Step)) == 1
      assert read.(other, Run) == []
      assert read.(other, Step) == []
    end

    test "a step's own writes are the job runner's alone", %{
      clinic: %{nurse: nurse, admin: admin}
    } do
      {:ok, run} = start(nurse)

      for member <- [nurse, admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Execution.step_agent_run(%{"id" => run.id},
                   actor: member.actor,
                   tenant: member.tenant
                 )
      end

      assert run(run).status == :queued
    end

    test "a request naming someone else's run as its parent is refused", %{clinic: clinic} do
      {:ok, run} = start(clinic.nurse)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Execution.invoke(
                 "AshEnterprise.Test.Execution.ClinicNote.record",
                 %{"title" => "SYNTHETIC: not mine"},
                 %{key: "borrowed:#{run.id}", parent: %{run_id: run.id, step_seq: 1}},
                 actor: clinic.admin.actor,
                 tenant: clinic.tenant
               )

      assert Exception.message(error) =~ "names work the requester does not own"
    end

    test "a new tenant's Administrator may read and cancel agent runs" do
      seeded = Seeder.seed_tenant(unique_name: "runs-#{System.unique_integer([:positive])}")

      for resource <- [Run, Step] do
        name = inspect(resource)

        granted =
          Security.RolePrivilege
          |> Ash.Query.filter(role_id == ^seeded.role.id and privilege.resource_name == ^name)
          |> Ash.Query.load(:privilege)
          |> Ash.read!(actor: SystemActor.seed(), tenant: seeded.organization.id)
          |> Enum.map(& &1.privilege.access_right)

        assert :read in granted
        if resource == Run, do: assert(:write in granted)
      end
    end
  end
end
