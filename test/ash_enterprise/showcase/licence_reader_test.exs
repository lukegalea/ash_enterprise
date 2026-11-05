defmodule AshEnterprise.Showcase.LicenceReaderTest do
  @moduledoc """
  Showcase slice 2 below the tour: the licence reader
  (`AshEnterprise.Credentialing.LicenceReader`) on the seeded clinic, in recorded mode
  (`AshEnterprise.Showcase.RecordedModel`), with no model and no key.

  A reading records typed findings citing the document lines they rest on; a model that
  times out mid-run resumes from the recorded lookups without looking again (F1); a
  long bundle runs out of budget with a typed reason (F8); erasing the clinician erases
  the run's journal and tool-call arguments while the rows and the audit chain stay
  (F11).

  Jobs are drained by hand: `:agent_runs` takes the steps, `:execution` the tool calls.
  """

  use AshEnterprise.DataCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]
  import Ecto.Query, only: [from: 2]

  alias AshEnterprise.AI.Models
  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Execution
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Credentialing, as: Tour
  alias AshEnterprise.Showcase.RecordedModel

  setup do
    admin = tenant!()
    %{admin: admin, tenant: admin.tenant, clinic: DemoData.populate(admin.tenant)}
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp credential(clinic, number), do: Enum.find(clinic.credentials, &(&1.number == number))

  # Takes steps and runs tool calls as their jobs do, until nothing is left to drain.
  defp drive!(run, tenant) do
    drain!()
    Execution.get_agent_run!(run.id, authorize?: false, tenant: tenant)
  end

  # What the run's `:step` jobs and its tool calls' `:execute` jobs do, until neither
  # queue has anything left.
  defp drain!(rounds \\ 12)
  defp drain!(0), do: :ok

  defp drain!(rounds) do
    steps = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    calls = Oban.drain_queue(queue: :execution, with_recursion: true)

    if steps.success + steps.failure + calls.success + calls.failure > 0,
      do: drain!(rounds - 1),
      else: :ok
  end

  defp reading(run, viewer) do
    viewer |> Tour.readings() |> Enum.find(&(&1.run.id == run.id))
  end

  test "the recorded model is in-zone and replays a case's turns from its transcript" do
    target = Models.resolve(Models.recorded_spec("credentialing.licence_reader"))
    assert {target.profile, target.residency} == {"recorded", :in_zone}

    assert RecordedModel.recorded?("credentialing.licence_reader")
    refute RecordedModel.recorded?("../credentialing.licence_reader")
    assert "DEMO-PT-0001" in RecordedModel.cases("credentialing.licence_reader")
  end

  test "a reading records typed findings that cite the lines they rest on", %{
    clinic: clinic,
    tenant: tenant
  } do
    rosa = actor(clinic.coordinator, tenant)
    credential = credential(clinic, "DEMO-PT-0001")

    assert {:ok, run} = Tour.start_reading(credential.id, rosa)
    done = drive!(run, tenant)
    assert done.status == :completed

    reading = reading(run, rosa)
    assert Enum.all?(reading.model_calls, &(&1.outcome == :ok))

    found = Map.new(reading.findings, &{&1.question, &1})
    assert found["licence_number"].value == "DEMO-PT-0001"
    assert found["licence_number"].status == "found"
    assert [%{line: 5, text: "Licence number: DEMO-PT-0001"}] = found["licence_number"].lines
    assert found["licence_valid_until"].value == "2028-06-30"
    assert [%{line: 6}] = found["licence_valid_until"].lines

    judgment = found["licence_number"].judgment
    assert judgment.run_id == to_string(run.id)
    assert judgment.invocation_id
    assert judgment.model_spec_requested == "recorded:credentialing.licence_reader"

    # On the case: the credential's detail says what was found and where.
    [loaded] =
      AshEnterprise.Credentialing.list_credentials!(
        actor: rosa,
        tenant: tenant,
        query: [filter: [id: credential.id]],
        load: [:document_findings]
      )

    assert loaded.document_findings =~ "Licence number: DEMO-PT-0001"
    assert loaded.document_findings =~ "line 5"
  end

  test "F1: the model times out after the lookups; the run resumes and looks nothing up again",
       %{clinic: clinic, tenant: tenant} do
    rosa = actor(clinic.coordinator, tenant)
    credential = credential(clinic, "DEMO-RN-0002")

    :ok = Tour.time_out_model_after_lookups()
    on_exit(fn -> Faults.disarm(Tour.timeout_point()) end)

    {:ok, run} = Tour.start_reading(credential.id, rosa)
    interrupted = drive!(run, tenant)
    assert interrupted.status == :running

    reading = reading(run, rosa)
    assert [%{outcome: :ok}, %{outcome: :error}] = reading.model_calls
    assert [_, _] = reading.lookups
    assert Enum.all?(reading.lookups, &(&1.status == :succeeded and &1.attempt_count == 1))

    # The lease runs out; the recover sweep queues the run again.
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      AshEnterprise.Repo.update_all(
        from(r in "exec_agent_runs", where: r.id == type(^run.id, Ecto.UUID)),
        set: [lease_expires_at: past]
      )

    {:ok, _} =
      Execution.recover_agent_run(interrupted, actor: SystemActor.oban(), tenant: tenant)

    done = drive!(run, tenant)
    assert done.status == :completed

    reading = reading(run, rosa)
    assert [:ok, :error, :ok, :ok] == Enum.map(reading.model_calls, & &1.outcome)
    assert Enum.all?(reading.lookups, &(&1.attempt_count == 1))
    assert length(reading.lookups) == 2
    assert length(reading.findings) == 2
  end

  test "F8: a long bundle runs out of budget, says why, and goes on once extended",
       %{clinic: clinic, tenant: tenant} do
    rosa = actor(clinic.coordinator, tenant)
    director = actor(clinic.director, tenant)
    credential = credential(clinic, "DEMO-OT-0003")

    {:ok, run} = Tour.start_reading(credential.id, rosa)
    waiting = drive!(run, tenant)

    assert {waiting.status, waiting.blocked_on, waiting.error_code} ==
             {:waiting, :budget, "token_budget"}

    assert {:error, %Ash.Error.Forbidden{}} = Tour.extend_budget(run.id, 4_000, rosa)
    assert {:ok, _} = Tour.extend_budget(run.id, 4_000, director)

    done = drive!(run, tenant)
    assert done.status == :completed

    found = Map.new(reading(run, rosa).findings, &{&1.question, &1})
    assert found["licence_valid_until"].status == "ambiguous"
    assert found["licence_valid_until"].value == nil
    assert [%{line: 6}, %{line: 7}] = found["licence_valid_until"].lines
  end

  test "F11: erasing the clinician erases the run's journal and tool-call arguments; the rows and the audit chain stay",
       %{admin: admin, clinic: clinic, tenant: tenant} do
    rosa = actor(clinic.coordinator, tenant)
    credential = credential(clinic, "DEMO-SLT-0004")

    {:ok, run} = Tour.start_reading(credential.id, rosa)
    assert drive!(run, tenant).status == :completed

    before = reading(run, rosa)
    assert Enum.all?(before.steps, & &1.recorded?)
    refute before.erased?

    assert {:error, %Ash.Error.Forbidden{}} = Tour.erase_clinician(credential.id, rosa)

    Seeder.grant_platform_operator(admin.user)
    operator = actor(admin.user, tenant)
    assert {:ok, %{status: :shredded}} = Tour.erase_clinician(credential.id, operator)

    after_erasure = reading(run, operator)
    assert after_erasure.erased?
    assert length(after_erasure.steps) == length(before.steps)
    refute Enum.any?(after_erasure.steps, & &1.recorded?)
    assert after_erasure.calls != []
    assert Enum.all?(after_erasure.calls, &Shredded.shredded?(&1.args))

    assert Tour.chain_verifies?(tenant)
  end
end
