defmodule AshEnterprise.Quality.NoLiveEffectsTest do
  @moduledoc """
  Evaluation causes no effects (ADR 0058, F12). An agent whose tools write inside the
  application, wait on a clinic lead's approval and call an outside board is run with
  `mode: :eval` (a suite case) and `mode: :shadow`, and asks for all three. Afterwards:

    * the business rows are as they were: no note, no approval task;
    * nothing tried to reach outside (`Req.Test` blocks and records every request);
    * every call is an invocation that was never claimed (no lease, no attempt, never
      `executing`), answered from the run's fixtures and marked `simulated`;
    * the run executed as the `evaluator` automation principal, for the person.

  A live run of the same script is the control: it writes the note, opens the approval
  task and calls the board, so the counts above would have seen an effect. A suite run
  then shows the same through `AshEnterprise.Quality`: its cases run with no effects and
  their results say what each run asked for.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Execution.Runs

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Quality
  alias AshEnterprise.Test.Execution, as: Notes
  alias AshEnterprise.Test.Execution.{Authority, NoNetwork}
  alias AshEnterprise.Test.Quality.Evaluee

  @agent "clinic.evaluee"
  @record "AshEnterprise.Test.Execution.ClinicNote.record"
  @approved "AshEnterprise.Test.Execution.ClinicNote.record_approved"
  @refer "AshEnterprise.Test.Execution.ReferralBoard.refer"

  setup do
    in_zone!()
    :ok = NoNetwork.block!()
    clinic = clinic!()
    version = published!(clinic, %{}, Evaluee)
    Authority.start_grant!(clinic.admin, clinic.admin, @agent)
    %{clinic: clinic, version: version}
  end

  # A model that asks for all three effects, then answers.
  defp script_every_effect!(title) do
    script!([
      {:tools,
       [
         {"note", "clinic_note_record", %{"input" => %{"title" => title}}},
         {"approved", "clinic_note_record_approved",
          %{"input" => %{"title" => title <> " (approved)"}}},
         {"refer", "referral_board_refer", %{"input" => %{"patient" => "SYNTHETIC patient 7"}}}
       ]},
      {:text, ~s({"done": true})}
    ])
  end

  defp fixtures, do: %{@record => %{"id" => "fixture-note"}, @refer => %{"referral" => "fixture"}}

  # The business rows an effect would have written, in the tenant.
  defp business_rows(tenant) do
    %{
      notes: length(Notes.list_notes!(tenant: tenant, authorize?: false)),
      approval_tasks: Ash.count!(HumanTask, tenant: tenant, authorize?: false)
    }
  end

  # Runs every job the run needs until it settles: its steps, and its tool calls'
  # `:execute` jobs.
  defp drive!(run) do
    for _round <- 1..4 do
      Oban.drain_queue(queue: :agent_runs)
      Oban.drain_queue(queue: :execution)
    end

    run(run)
  end

  defp settled?(suite_run),
    do:
      Quality.get_suite_run!(suite_run.id, [load: [:settled]] ++ oban(suite_run.organization_id)).settled

  defp finish_suite_runs! do
    AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
  end

  defp refute_outbound_request do
    refute_received {:outbound_request, _method, _host, _path}
  end

  for mode <- [:eval, :shadow] do
    @mode mode

    test "a #{mode} run asks for every effect and causes none", %{clinic: clinic} do
      %{admin: admin, tenant: tenant} = clinic
      title = "SYNTHETIC: #{@mode} note #{System.unique_integer([:positive])}"
      before = business_rows(tenant)
      script_every_effect!(title)

      {:ok, run} =
        Execution.start_agent_run(
          @agent,
          "SYNTHETIC: record the panel and refer patient 7.",
          %{mode: @mode, fixtures: fixtures(), origin: :eval},
          actor: admin.actor,
          tenant: tenant
        )

      assert run.mode == @mode

      assert {"automation", "evaluator", admin.user.id, @agent} ==
               AshAgent.ExecutionIdentity.identity(run.executing_principal)

      done = drive!(run)
      assert done.status == :completed

      # Nothing changed and nothing left the machine.
      assert business_rows(tenant) == before
      refute_outbound_request()

      # Every call was asked for and answered from the fixtures. None reached
      # `executing`: a claim is the only way there, and every claim takes a lease
      # (`lease_epoch` + 1) and counts an attempt.
      calls = Map.new(invocations(run), &{&1.target, &1})
      assert Map.keys(calls) |> Enum.sort() == Enum.sort([@record, @approved, @refer])

      for {_target, call} <- calls do
        assert {call.mode, call.simulated, call.lease_epoch, call.attempt_count} ==
                 {@mode, true, 0, 0}

        assert call.status in [:succeeded, :failed]
        assert is_nil(call.approval_digest)
      end

      assert {calls[@record].status, calls[@refer].status} == {:succeeded, :succeeded}
      # No fixture answers the approved write: it fails, with no approval opened.
      assert {calls[@approved].status, calls[@approved].error_code} == {:failed, "no_fixture"}
      assert calls[@approved].approval_mode == :four_eyes

      result = Ash.load!(calls[@refer], [:result], oban(tenant)).result
      assert result == %{"referral" => "fixture"}
    end
  end

  test "a live run of the same script causes the effects the counts look for", %{clinic: clinic} do
    %{admin: admin, tenant: tenant} = clinic
    title = "SYNTHETIC: live note #{System.unique_integer([:positive])}"
    before = business_rows(tenant)
    script_every_effect!(title)

    {:ok, run} = start(admin, "SYNTHETIC: record the panel and refer patient 7.", @agent)
    assert run.mode == :live
    _run = drive!(run)

    after_live = business_rows(tenant)
    assert after_live.notes == before.notes + 1
    assert after_live.approval_tasks > before.approval_tasks
    assert_received {:outbound_request, _method, _host, _path}

    assert Enum.all?(invocations(run), &(&1.simulated == false))
  end

  describe "a suite run" do
    setup %{clinic: clinic} do
      %{admin: admin, tenant: tenant} = clinic

      suite =
        Quality.create_suite_draft!(
          "clinic.evaluee.smoke",
          %{
            cases: [
              %{
                id: "records-and-refers",
                input: "SYNTHETIC: record the panel and refer patient 7.",
                fixtures: fixtures(),
                split: :dev,
                assertions: [
                  %{type: :tool_called, target: @record},
                  %{
                    type: :args_match,
                    target: @refer,
                    args: %{"patient" => "SYNTHETIC patient 7"}
                  },
                  %{type: :approval_requested, target: @approved},
                  %{type: :prohibited_effect, target: @refer},
                  %{type: :max_steps, limit: 4},
                  %{type: :cites}
                ]
              }
            ],
            thresholds: %{"pass_rate" => 1.0}
          },
          actor: admin.actor,
          tenant: tenant
        )
        |> Quality.publish_suite!(actor: admin.actor, tenant: tenant)

      %{suite: suite}
    end

    for mode <- [:offline, :shadow] do
      @mode mode

      test "#{mode}: its cases cause no effects and its results say what each run asked for",
           %{clinic: clinic, suite: suite, version: version} do
        %{admin: admin, tenant: tenant} = clinic
        before = business_rows(tenant)
        script_every_effect!("SYNTHETIC: suite note")

        suite_run =
          Quality.start_suite_run!(suite.id, @agent, %{mode: @mode},
            actor: admin.actor,
            tenant: tenant
          )

        assert {suite_run.agent_version_id, suite_run.candidate_digest,
                suite_run.suite_content_hash} ==
                 {version.id, version.content_hash, suite.content_hash}

        [run] =
          Execution.list_agent_runs!(
            query: [filter: [run_key: "quality:#{suite_run.id}:records-and-refers:1"]],
            authorize?: false,
            tenant: tenant
          )

        assert {run.mode, run.origin} == {if(@mode == :offline, do: :eval, else: :shadow), :eval}

        refute settled?(suite_run)
        # Its finish waits for its cases.
        finish_suite_runs!()
        assert Quality.get_suite_run!(suite_run.id, oban(tenant)).status == :running

        drive!(run)
        assert business_rows(tenant) == before
        refute_outbound_request()

        # The :finish trigger scores it once its case's run has finished.
        assert settled?(suite_run)
        finish_suite_runs!()
        finished = Quality.get_suite_run!(suite_run.id, oban(tenant))
        assert finished.status == :finished

        [result] =
          Quality.list_case_results!(
            query: [filter: [suite_run_id: suite_run.id]],
            actor: admin.actor,
            tenant: tenant
          )

        statuses = Map.new(result.assertion_results, &{&1["type"], &1["status"]})

        assert statuses == %{
                 "tool_called" => "passed",
                 "args_match" => "passed",
                 "approval_requested" => "passed",
                 "prohibited_effect" => "failed",
                 "max_steps" => "passed",
                 "cites" => "unmeasured"
               }

        # It asked for the referral the case prohibits: a hard failure, in the safety lane.
        assert {result.status, result.prohibited_effect_hit, result.owner_id} ==
                 {:failed, true, admin.user.id}

        assert finished.summary["safety"] == %{
                 "hard_failures" => 1,
                 "prohibited_effect_hits" => 1
               }

        assert finished.summary["quality"]["pass_rate"] == 0.0
      end
    end

    test "is refused for a draft suite, and starts nothing", %{clinic: clinic} do
      %{admin: admin, tenant: tenant} = clinic

      draft =
        Quality.create_suite_draft!("clinic.evaluee.draft", %{},
          actor: admin.actor,
          tenant: tenant
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Quality.start_suite_run(draft.id, @agent, actor: admin.actor, tenant: tenant)

      assert Execution.list_agent_runs!(
               query: [filter: [origin: :eval]],
               authorize?: false,
               tenant: tenant
             ) == []
    end

    test "a published suite's cases are frozen", %{clinic: clinic, suite: suite} do
      %{admin: admin, tenant: tenant} = clinic

      assert {:error, %Ash.Error.Invalid{}} =
               Quality.add_suite_case(suite, %{id: "late", input: "x"},
                 actor: admin.actor,
                 tenant: tenant
               )
    end
  end
end
